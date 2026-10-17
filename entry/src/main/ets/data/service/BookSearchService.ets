import { Chapter } from '../../model/Chapter';
import { Book } from '../../model/Book';
import { BookRepository } from '../repository/BookRepository';
import { RawFileSource } from '../source/RawFileSource';
import { ChapterReadService } from './ChapterReadService';
import { LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';
import { PathUtil } from '../../common/utils/PathUtil';

/**
 * 全书内容搜索的一条命中。
 *
 * ⚠️ `offset` 是【章内解码文本的 UTF-16 下标】—— 与
 * `ReaderJump.offset`、`switchChapter(chapterIndex, offset)` 的语义
 * **逐字一致**（都出自 `ChapterReadService.decodeChapter` 的同一出口），
 * 搜索结果跳转不需要任何换算。
 */
export class BookSearchHit {
  /** 0-based 章序号 */
  chapterIndex: number = 0;
  /** 章标题（冗余一份，结果列表直接显示，免得再查） */
  chapterTitle: string = '';
  /** 命中词在章内解码文本中的 UTF-16 下标 */
  offset: number = 0;
  /** 命中处的上下文片段（命中词以【】包起，供 UI 直接高亮/加粗） */
  snippet: string = '';
}

/**
 * 全书内容搜索（纯文本 indexOf，一次性扫描）。
 *
 * 为什么不做全文索引：本书籍体量（单本几 MB、章节几十~几千个）
 * 下逐章解码 + indexOf 是毫秒到亚秒级，而建索引需要额外的表、
 * 触发式更新（重新分章/换编码都要重建）、以及一套查询语法 ——
 * 复杂度全部超出收益。判据：**数据量小时，蛮力扫描优于索引。**
 *
 * 防御边界（都在常量里）：
 *  - 单章命中数封顶（`SEARCH_HITS_PER_CHAPTER`）——"第 3 章是主角名字的出处"
 *    这种章节会刷出上百条，淹掉真正分散在全书的结果；
 *  - 全书命中数封顶（`SEARCH_HITS_MAX`）——UI 列表只需要"够翻的量"，
 *    超限即在结果尾部提示"已截断"；
 *  - 扫描在调用方的异步上下文里跑，本服务自身不开线程
 *    （ArkTS 侧没有廉价的多线程通道，且毫秒级任务不值得）。
 */
export class BookSearchService {
  /** 单章命中上限：超过则本章剩余位置跳过（同一章刷屏没有信息量） */
  private static readonly HITS_PER_CHAPTER: number = 5;
  /** 全书命中上限：UI 一次渲染几百条已是极限 */
  private static readonly HITS_MAX: number = 200;

  /**
   * 搜索整本书。
   *
   * @param bookId  书 id
   * @param keyword 关键词（trim 后非空；空串返回空结果）
   * @param chapters 章节列表（调用方通常已在内存里，避免重复查库）
   * @returns 命中列表（按章序排列）；`truncated=true` 表示超过上限被截断
   */
  static async search(
    bookId: number, keyword: string, chapters: Chapter[]
  ): Promise<BookSearchResult> {
    const result = new BookSearchResult();
    const needle: string = keyword.trim();
    if (needle.length === 0 || chapters.length === 0) {
      return result;
    }

    let book: Book | null = null;
    try {
      book = await BookRepository.getById(bookId);
    } catch (e) {
      Logger.error(LogTag.READ, `搜索取书失败: ${Logger.errText(e as Object)}`);
      return result;
    }
    if (book === null || book.filePath.length === 0 || !PathUtil.exists(book.filePath)) {
      return result;
    }

    const absolutePath: string = PathUtil.toAbsolute(book.filePath);
    const source = RawFileSource.tryOpen(absolutePath);
    if (source === null) {
      return result;
    }
    // 独立的 readService 实例（不复用阅读页那份）：缓存互不污染，用完即走
    const reader = new ChapterReadService(source, book.encoding, bookId);
    const lowerNeedle: string = needle.toLowerCase();
    try {
      for (const chapter of chapters) {
        if (result.hits.length >= BookSearchService.HITS_MAX) {
          result.truncated = true;
          break;
        }
        const chapterText: string = reader.decodeChapter(
          chapter.startOffset, chapter.endOffset, null);
        if (chapterText.length === 0) {
          continue;
        }
        BookSearchService.collectHits(chapterText, lowerNeedle, chapter, result);
      }
    } finally {
      // 无论扫到哪一步，文件句柄必须还掉 —— 搜索页随时可能被用户退出
      reader.dispose();
    }
    return result;
  }

  /** 在一章内找出全部命中（受单章上限约束），并生成带【】标记的片段 */
  private static collectHits(
    text: string, lowerNeedle: string, chapter: Chapter, result: BookSearchResult
  ): void {
    // 大小写不敏感：小写化一次整章文本（几百 KB 一次摊薄），循环里只做 indexOf
    const lowerText: string = text.toLowerCase();
    const needleLen: number = lowerNeedle.length;
    let from: number = 0;
    let inChapter: number = 0;
    const title: string = chapter.title.length > 0
      ? chapter.title : `第 ${chapter.displayNumber()} 章`;

    while (result.hits.length < BookSearchService.HITS_MAX
      && inChapter < BookSearchService.HITS_PER_CHAPTER) {
      const at: number = lowerText.indexOf(lowerNeedle, from);
      if (at < 0) {
        break;
      }
      const hit = new BookSearchHit();
      hit.chapterIndex = chapter.chapterIndex;
      hit.chapterTitle = title;
      hit.offset = at;
      hit.snippet = BookSearchService.snippetOf(text, at, needleLen);
      result.hits.push(hit);
      inChapter++;
      from = at + needleLen;
    }
  }

  /**
   * 取命中前后各约 18 个字的上下文，命中词用【】包起。
   *
   * ⚠️ 必须**前 / 命中 / 后三段分别折叠空白再拼接**：
   * 先整体 `replace(/\s+/g,' ')` 会改变长度，命中词的下标就漂移了，
   * 【】会套到别的字上。三段各自折叠，拼接处的偏移天然正确。
   */
  private static snippetOf(text: string, at: number, needleLen: number): string {
    const CONTEXT: number = 18;
    const start: number = Math.max(0, at - CONTEXT);
    const end: number = Math.min(text.length, at + needleLen + CONTEXT);
    const head: string = BookSearchService.flat(text.substring(start, at));
    const mid: string = BookSearchService.flat(text.substring(at, at + needleLen));
    const tail: string = BookSearchService.flat(text.substring(at + needleLen, end));
    return `${head}【${mid}】${tail}`;
  }

  /** 折行/连续空白压成单空格：保证片段在结果列表里单行可读 */
  private static flat(part: string): string {
    return part.replace(/\s+/g, ' ').trim();
  }
}

/** 搜索结果（hits + 截断标记） */
export class BookSearchResult {
  hits: BookSearchHit[] = [];
  /** true = 命中数超过上限，列表只是部分结果 */
  truncated: boolean = false;
}
