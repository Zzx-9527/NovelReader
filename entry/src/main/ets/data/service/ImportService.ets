import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { Book } from '../../model/Book';
import { Chapter } from '../../model/Chapter';
import { BookRepository, HashLookup } from '../repository/BookRepository';
import { ChapterRepository } from '../repository/ChapterRepository';
import { PageCacheRepository } from '../repository/PageCacheRepository';
import { RdbHelper } from '../database/RdbHelper';
import { RawFileSource } from '../source/RawFileSource';
import { FilePickerSource } from '../source/FilePickerSource';
import { PathUtil } from '../../common/utils/PathUtil';
import { HashUtil } from '../../common/utils/HashUtil';
import {
  EncodingDetector, DetectionResult, Confidence, Encodings
} from '../../common/utils/EncodingDetector';
import { ChapterParser, ParseResult, ParsedChapter } from '../../common/utils/ChapterParser';
import { Logger } from '../../common/utils/Logger';
import { AppConstants, LogTag } from '../../common/constants/AppConstants';

/** 导入最终状态 */
export enum ImportOutcome {
  SUCCESS = 0,
  /** 用户在文件选择器里取消了 */
  CANCELLED = 1,
  /** 书架里已有同一本书（未删除） */
  DUPLICATE_ACTIVE = 2,
  /**
   * 保留值：历史版本曾用它表示"命中已删除的同一文件，等用户选择"。
   * 现在这个分支已改为直接清理旧记录后正常导入 —— 挂起等选择会让用户
   * 觉得"点了导入没反应"。留着枚举位以免与旧数据/日志对不上。
   */
  DUPLICATE_DELETED = 3,
  FAILED = 4
}

/** 导入阶段（驱动进度 UI） */
export enum ImportStage {
  IDLE = 0,
  COPYING = 1,
  HASHING = 2,
  DETECTING = 3,
  PARSING = 4,
  SAVING = 5,
  DONE = 6
}

export class ImportProgress {
  stage: ImportStage = ImportStage.IDLE;
  /** 0~1；未知时为 -1 */
  percent: number = -1;
  message: string = '';
}

export type ImportProgressCallback = (progress: ImportProgress) => void;

export class ImportResult {
  outcome: ImportOutcome = ImportOutcome.FAILED;
  /** 新导入或已存在的书籍 id */
  bookId: number = 0;
  /** 命中重复时已存在的那本书 */
  existingBook: Book | null = null;
  encoding: string = '';
  /** 编码探测置信度低，UI 应引导用户手选编码后重新解析 */
  lowConfidence: boolean = false;
  chapterCount: number = 0;
  wordCount: number = 0;
  /** 是否走了兜底切分 */
  fallback: boolean = false;
  /** 失败原因（面向用户的简短文案） */
  error: string = '';
}

/**
 * 阶段一产物：交给导入确认页展示（编码、分章预览），再由调用方决定是否 commit。
 */
export class ImportPreparation {
  result: ImportResult = new ImportResult();
  uri: string = '';
  uuid: string = '';
  /** 沙箱相对路径 */
  relativePath: string = '';
  fileSize: number = 0;
  fileHash: string = '';
  encoding: string = '';
  chapters: ParsedChapter[] = [];
  parseRule: string = '';
  fallback: boolean = false;
}

/**
 * 导入服务：文件选择 → 沙箱复制 → 内容指纹 → 编码探测 → 分章 → 批量入库。
 *
 * 有意拆成 prepare / commit 两阶段：
 *   prepare() 只读沙箱、只做解析，产物交给导入确认页；
 *   commit()  才真正写库。
 * 这样才能实现"编码选择 + 分章预览 + 确认导入"的界面流程。
 */
export class ImportService {
  // ------------------------------------------------------------ 阶段一：准备

  /**
   * 复制到沙箱 + 指纹判重 + 编码探测 + 分章解析（不写业务表）。
   *
   * @param uri                picker 返回的 URI
   * @param preferredEncoding  用户已确认的编码；空串表示自动探测
   */
  static async prepare(
    uri: string, preferredEncoding: string = '', callback?: ImportProgressCallback
  ): Promise<ImportPreparation> {
    const preparation = new ImportPreparation();
    const result = new ImportResult();
    preparation.result = result;
    preparation.uri = uri;

    if (uri === undefined || uri === null || uri.length === 0) {
      result.outcome = ImportOutcome.CANCELLED;
      return preparation;
    }

    const uuid: string = ImportService.makeUuid();
    preparation.uuid = uuid;
    const relativePath: string = PathUtil.bookRelativePath(uuid);
    const absolutePath: string = PathUtil.toAbsolute(relativePath);
    PathUtil.ensureDir(PathUtil.booksDir());

    // 1) 复制到沙箱（picker 的 URI 授权是临时的）
    ImportService.report(callback, ImportStage.COPYING, -1, '正在复制文件…');
    try {
      await FilePickerSource.copyToSandbox(uri, absolutePath);
    } catch (e) {
      result.outcome = ImportOutcome.FAILED;
      result.error = `复制文件失败：${Logger.errText(e as BusinessError)}`;
      return preparation;
    }

    const fileSize: number = PathUtil.fileSize(relativePath);
    if (fileSize <= 0) {
      result.outcome = ImportOutcome.FAILED;
      result.error = '文件为空或无法读取';
      ImportService.deleteSandboxFile(absolutePath);
      return preparation;
    }
    preparation.fileSize = fileSize;
    preparation.relativePath = relativePath;

    // 2) 内容指纹 + 判重（三分支：在架 / 已删除 / 未命中）
    ImportService.report(callback, ImportStage.HASHING, -1, '正在校验文件…');
    let fileHash: string = '';
    try {
      fileHash = await HashUtil.fileSha256(absolutePath);
    } catch (e) {
      // 指纹算不出来不该阻断导入，只是失去去重能力
      Logger.warn(LogTag.IMPORT, `计算文件指纹失败: ${Logger.errText(e as BusinessError)}`);
    }
    preparation.fileHash = fileHash;

    if (fileHash.length > 0) {
      const lookup = await BookRepository.findByHash(fileHash);
      if (lookup.status === HashLookup.ACTIVE) {
        result.outcome = ImportOutcome.DUPLICATE_ACTIVE;
        result.existingBook = lookup.book;
        result.bookId = lookup.book !== null ? lookup.book.id : 0;
        result.error = '这本书已经在书架里了';
        ImportService.deleteSandboxFile(absolutePath);
        return preparation;
      }
      // 命中"已删除的同一文件"：不挂起、不询问，直接导入。
      //
      // 之前这里返回 DUPLICATE_DELETED 等用户选"恢复还是作为新书"，
      // 结果是用户点导入没反应（状态被挂起、流程中断）—— 那不符合直觉。
      // 用户的意图很明确："我要导入"。所以这里只做一件事：
      // 把阻挡唯一索引的旧记录物理删掉（连同它的孤儿文件），让本次导入正常走完。
      if (lookup.status === HashLookup.DELETED && lookup.book !== null) {
        const stale = lookup.book;
        Logger.info(LogTag.IMPORT,
          `清理已删除的同文件记录后重新导入: oldBookId=${stale.id}`);
        await BookRepository.hardDelete(stale.id);
        if (stale.filePath.length > 0 && stale.filePath !== relativePath) {
          ImportService.deleteSandboxFile(PathUtil.toAbsolute(stale.filePath));
        }
      }
    }

    // 3) 编码探测
    ImportService.report(callback, ImportStage.DETECTING, -1, '正在识别编码…');
    let encoding: string = preferredEncoding;
    if (encoding.length === 0) {
      const source = RawFileSource.tryOpen(absolutePath);
      if (source === null) {
        result.outcome = ImportOutcome.FAILED;
        result.error = '无法读取文件';
        return preparation;
      }
      try {
        const detection: DetectionResult = EncodingDetector.detect(source);
        encoding = detection.encoding;
        result.lowConfidence = detection.confidence === Confidence.LOW;
      } finally {
        source.close();
      }
    }
    encoding = EncodingDetector.normalizeEncoding(encoding);
    preparation.encoding = encoding;
    result.encoding = encoding;

    // 4) 分章解析
    ImportService.report(callback, ImportStage.PARSING, -1, '正在解析章节…');
    // 说明：这一步是 CPU 密集的（整文件解码 + 行级正则 + 逐行字节换算），
    // 大文件（10 MB+）会有明显停顿。彻底的解法是放进 taskpool，
    // 但那要求把解析器与文件访问做成可序列化的任务体，属后续优化。
    const parseResult: ImportResult = ImportService.parseInto(preparation, encoding);
    if (parseResult.outcome === ImportOutcome.FAILED) {
      return preparation;
    }

    result.outcome = ImportOutcome.SUCCESS;
    return preparation;
  }

  /**
   * 单独执行"分章解析"，用于用户在确认页换了编码后重新预览。
   * 会覆盖 preparation 里的 chapters / parseRule / encoding。
   */
  static parseInto(preparation: ImportPreparation, encoding: string): ImportResult {
    const result = preparation.result;
    const absolutePath: string = PathUtil.toAbsolute(preparation.relativePath);

    if (!PathUtil.exists(preparation.relativePath)) {
      result.outcome = ImportOutcome.FAILED;
      result.error = '文件已丢失，请重新选择';
      return result;
    }

    const source = RawFileSource.tryOpen(absolutePath);
    if (source === null) {
      result.outcome = ImportOutcome.FAILED;
      result.error = '无法打开文件';
      return result;
    }

    let parsed: ParseResult;
    try {
      parsed = ChapterParser.parse(source, encoding);
    } catch (e) {
      result.outcome = ImportOutcome.FAILED;
      result.error = `解析失败：${Logger.errText(e as BusinessError)}`;
      return result;
    } finally {
      source.close();
    }

    if (parsed.chapters.length === 0) {
      result.outcome = ImportOutcome.FAILED;
      result.error = '没有解析出任何章节，可尝试更换编码';
      return result;
    }

    preparation.encoding = encoding;
    preparation.chapters = parsed.chapters;
    preparation.parseRule = parsed.rule;
    preparation.fallback = parsed.fallback;
    result.encoding = encoding;
    result.chapterCount = parsed.chapters.length;
    result.wordCount = parsed.totalWordCount;
    result.fallback = parsed.fallback;
    result.outcome = ImportOutcome.SUCCESS;
    result.error = '';
    return result;
  }

  // ------------------------------------------------------------ 阶段二：入库

  /**
   * 把 prepare() 的产物写入数据库。
   *
   * 章节批量写入与 book 更新在同一个事务里，要么全成要么全不成 ——
   * 避免出现"书在架但一章都没有"的僵尸记录。
   */
  static async commit(
    preparation: ImportPreparation, bookTitle: string = '',
    callback?: ImportProgressCallback
  ): Promise<ImportResult> {
    const result = preparation.result;
    if (result.outcome !== ImportOutcome.SUCCESS) {
      return result;
    }

    ImportService.report(callback, ImportStage.SAVING, -1, '正在保存…');

    const book = new Book();
    book.uuid = preparation.uuid;
    book.title = bookTitle.length > 0
      ? bookTitle
      : PathUtil.fileNameWithoutExt(preparation.uri);
    book.filePath = preparation.relativePath;
    book.format = AppConstants.FORMAT_TXT;
    book.encoding = preparation.encoding;
    book.fileSize = preparation.fileSize;
    book.fileHash = preparation.fileHash;
    book.totalChapters = preparation.chapters.length;
    book.wordCount = result.wordCount;
    book.parseStatus = AppConstants.PARSE_SUCCESS;
    book.parseRule = preparation.parseRule;
    book.lastChapterIndex = -1;

    const db = RdbHelper.getInstance();
    try {
      const bookId: number = await db.withTransaction<number>(async () => {
        const newId: number = await BookRepository.insert(book);
        if (newId <= 0) {
          throw new Error('写入书籍记录失败');
        }
        await ChapterRepository.insertBatch(newId, ImportService.toChapters(newId, preparation.chapters));
        await BookRepository.updateParseState(
          newId, AppConstants.PARSE_SUCCESS, '', preparation.parseRule,
          preparation.chapters.length, result.wordCount);
        return newId;
      });
      result.bookId = bookId;
      result.outcome = ImportOutcome.SUCCESS;
      ImportService.report(callback, ImportStage.DONE, 1, '导入完成');
    } catch (e) {
      result.outcome = ImportOutcome.FAILED;
      result.error = `保存失败：${Logger.errText(e as BusinessError)}`;
      ImportService.deleteSandboxFile(PathUtil.toAbsolute(preparation.relativePath));
      return result;
    }

    // 分章结果已确定，旧的分页缓存必然失效
    await PageCacheRepository.deleteByBook(result.bookId);
    return result;
  }

  /**
   * 一步完成导入（无确认页时使用）。
   * 需要"编码确认"界面时请改用 prepare() + commit()。
   */
  static async importFromUri(
    uri: string, callback?: ImportProgressCallback
  ): Promise<ImportResult> {
    const preparation = await ImportService.prepare(uri, '', callback);
    if (preparation.result.outcome !== ImportOutcome.SUCCESS) {
      return preparation.result;
    }
    return ImportService.commit(preparation, '', callback);
  }

  /** 放弃一次 prepare 的产物（用户点了取消），清理已复制的沙箱文件 */
  static discard(preparation: ImportPreparation): void {
    if (preparation.relativePath.length === 0) {
      return;
    }
    ImportService.deleteSandboxFile(PathUtil.toAbsolute(preparation.relativePath));
  }

  /**
   * 以用户选定的编码重新分章并覆盖入库。
   *
   * ⚠️ 会因外键 CASCADE 删除该书全部书签/划线/笔记。
   * 调用方必须先向用户确认（可用 ChapterRepository.countAnnotationsImpacted 取数量）。
   *
   * ⚠️ 性能：这是 CPU 密集操作（整文件解码 + 行级正则 + 逐行字节换算 + 全量重写章节）。
   * 10 MB 级别的小说会有数秒停顿，调用方必须给出可见进度（ShelfState.reparseMessage），
   * 否则用户会以为卡死。
   */
  static async reparse(
    bookId: number, encoding: string = ''
  ): Promise<ImportResult> {
    const result = new ImportResult();

    const book = await BookRepository.getById(bookId);
    if (book === null) {
      result.outcome = ImportOutcome.FAILED;
      result.error = '书籍不存在';
      return result;
    }
    if (!PathUtil.exists(book.filePath)) {
      result.outcome = ImportOutcome.FAILED;
      result.error = '文件丢失';
      await BookRepository.markFileMissing(bookId, book.parseRule);
      return result;
    }

    const useEncoding: string = encoding.length > 0 ? encoding : book.encoding;
    const absolutePath: string = PathUtil.toAbsolute(book.filePath);
    const source = RawFileSource.tryOpen(absolutePath);
    if (source === null) {
      result.outcome = ImportOutcome.FAILED;
      result.error = '无法打开文件';
      return result;
    }

    let parsed: ParseResult;
    try {
      parsed = ChapterParser.parse(source, useEncoding);
    } finally {
      source.close();
    }

    if (parsed.chapters.length === 0) {
      result.outcome = ImportOutcome.FAILED;
      result.error = '没有解析出任何章节，可尝试更换编码';
      return result;
    }

    const rows: Chapter[] = ImportService.toChapters(bookId, parsed.chapters);
    const db = RdbHelper.getInstance();
    await db.withTransaction<void>(async () => {
      // 注意顺序：先删章节（连带删标注），再写入新章节
      await ChapterRepository.deleteByBook(bookId);
      await ChapterRepository.insertBatch(bookId, rows);
      await BookRepository.updateParseState(
        bookId, AppConstants.PARSE_SUCCESS, '', parsed.rule, rows.length, parsed.totalWordCount);
      // 章节序号整体变化，旧进度不再有意义：显式复位，而不是留一个可能越界的序号
      await BookRepository.updateProgress(
        bookId, -1, 0, 0, '', AppConstants.READ_STATUS_UNREAD);
    });
    await PageCacheRepository.deleteByBook(bookId);

    result.outcome = ImportOutcome.SUCCESS;
    result.bookId = bookId;
    result.encoding = useEncoding;
    result.chapterCount = rows.length;
    result.wordCount = parsed.totalWordCount;
    result.fallback = parsed.fallback;
    return result;
  }

  /** 删除书籍时清理沙箱文件（供"清理回收站"调用） */
  static deleteSandboxFile(absolutePath: string): void {
    try {
      if (fs.accessSync(absolutePath)) {
        fs.unlinkSync(absolutePath);
      }
    } catch (e) {
      Logger.warn(LogTag.IMPORT, `删除沙箱文件失败: ${absolutePath}`);
    }
  }

  // ------------------------------------------------------------ 内部工具

  /**
   * 生成书籍 uuid。
   *
   * 不用裸的 `util.generateRandomUUID`：它一旦抛错会让整个导入在最开头失败，
   * 且失败原因对用户毫无意义。这里做降级 —— 时间戳 + 递增序号同样唯一。
   */
  private static uuidSeq: number = 0;

  private static makeUuid(): string {
    try {
      return util.generateRandomUUID(true);
    } catch (e) {
      ImportService.uuidSeq++;
      return `book-${Date.now()}-${ImportService.uuidSeq}`;
    }
  }

  private static toChapters(bookId: number, parsed: ParsedChapter[]): Chapter[] {
    const rows: Chapter[] = [];
    for (const p of parsed) {
      const chapter = new Chapter();
      chapter.bookId = bookId;
      chapter.chapterIndex = p.chapterIndex;
      chapter.title = p.title;
      chapter.startOffset = p.startOffset;
      chapter.endOffset = p.endOffset;
      chapter.level = p.level;
      chapter.wordCount = p.wordCount;
      rows.push(chapter);
    }
    return rows;
  }

  private static report(
    callback: ImportProgressCallback | undefined, stage: ImportStage,
    percent: number, message: string
  ): void {
    if (callback === undefined || callback === null) {
      return;
    }
    const progress = new ImportProgress();
    progress.stage = stage;
    progress.percent = percent;
    progress.message = message;
    callback(progress);
  }
}
