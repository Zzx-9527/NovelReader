import { ByteSource } from '../../data/source/ByteSource';
import { StreamTextReader } from './StreamTextReader';
import { AppConstants, LogTag } from '../constants/AppConstants';
import { Logger } from './Logger';

/** 解析出的章节（尚未入库，字段与 model/Chapter 对齐但无 id） */
export class ParsedChapter {
  /** 0-based */
  chapterIndex: number = 0;
  title: string = '';
  /** 原文件字节偏移（含） */
  startOffset: number = 0;
  /** 原文件字节偏移（不含）；null 表示到文件末尾 */
  endOffset: number | null = null;
  /** 0 = 章，1 = 卷 */
  level: number = 0;
  wordCount: number = 0;
}

/** 分章结果 */
export class ParseResult {
  chapters: ParsedChapter[] = [];
  /** 命中的规则名，写入 book.parse_rule */
  rule: string = 'fallback';
  totalWordCount: number = 0;
  /** 是否走了兜底切分（说明这本书章节结构不标准，UI 可提示"可尝试重新分章"） */
  fallback: boolean = false;
  /**
   * 分章质量可疑（编码可能选错了）。
   *
   * ⚠️ 判据是"**兜底切分 + 章数极少**"：正常小说兜底也该切出几十章，
   * 只有个位数说明 `bytesPerChar` 被算得极大 —— 而那正是**用错编码**的特征
   * （例如给 GBK 文件选 utf-16，字节/字符比会从约 2 暴涨到接近 1 个"字"占 4 字节）。
   * UI 据此提示用户"换一个编码再试"，而不是让这本书悄悄留在书架上。
   */
  suspicious: boolean = false;
}

/** 分章规则 */
class ChapterRule {
  name: string;
  regex: RegExp;
  level: number;

  constructor(name: string, regexSource: string, level: number) {
    this.name = name;
    this.regex = new RegExp(regexSource);
    this.level = level;
  }
}

/** 章节标记在原文件中的字节位置 */
class Marker {
  /** 标题行首的字节偏移 */
  byteOffset: number = 0;
  /** 正文首字节偏移（= byteOffset + 标题行含换行符的字节长度） */
  contentStartOffset: number = 0;
  title: string = '';
  level: number = 0;
}

/** 扫描产物，供第二遍连成章节 */
class ScanOutcome {
  markers: Marker[] = [];
  ruleIndex: number = -1;
  ruleName: string = 'fallback';
  fileSize: number = 0;
  textLength: number = 0;
  byteLength: number = 0;
}

const CN_NUM: string = '一二三四五六七八九十百千零两0-9０-９';

/** 高置信度规则，按优先级自上而下匹配（一行只归属第一条命中的规则） */
const HIGH_RULES: ChapterRule[] = [
  new ChapterRule('cn_volume', `^第\\s*[${CN_NUM}]+\\s*[卷部篇]\\s*[^\\n]{0,30}$`, 1),
  new ChapterRule('cn_chapter', `^第\\s*[${CN_NUM}]+\\s*[章节回]\\s*[^\\n]{0,30}$`, 0),
  new ChapterRule('cn_bare', `^[${CN_NUM}]{1,6}\\s*[章节回]\\s*[^\\n]{0,30}$`, 0),
  new ChapterRule('en_chapter', `^CHAPTER\\s+([0-9]{1,4}|[IVXLC]{1,8})\\b[^\\n]{0,40}$`, 0),
  new ChapterRule('cn_special', `^(正文|序章|楔子|前言|后记|尾声|番外)\\s*[^\\n]{0,30}$`, 0)
];

/**
 * TXT 分章解析器。
 *
 * 算法（设计文档 6.3）：
 *  1. 用 StreamTextReader 分块流式解码，跨块残字节由 StringDecoder 处理；
 *  2. 跨块保留"未处理完的尾巴"，只对完整的行做匹配 ——
 *     这样游标 lineStartByte 永远与缓冲区起点对齐，不需要任何修正项；
 *  3. 每消费一行，推进 lineStartByte += encoder.encode(该行含换行符).length，
 *     于是命中行的 lineStartByte 就是精确的 chapter.start_offset；
 *  4. 命中数不足时降级到固定字节数切分，保证任何文件都能读。
 */
export class ChapterParser {
  /**
   * @param source   字节源（调用方负责 close）
   * @param encoding 已确认的编码
   */
  static parse(source: ByteSource, encoding: string): ParseResult {
    const outcome: ScanOutcome = ChapterParser.scan(source, encoding);
    return ChapterParser.buildChapters(outcome);
  }

  /** 第一遍：顺序扫描全文，收集候选章节标记的字节位置 */
  private static scan(source: ByteSource, encoding: string): ScanOutcome {
    const outcome = new ScanOutcome();
    outcome.fileSize = source.size();

    const reader = new StreamTextReader(source, encoding);
    const hitsByRule: Marker[][] = [];
    for (let i = 0; i < HIGH_RULES.length; i++) {
      hitsByRule.push([]);
    }

    // 缓冲区起点对应的文件字节偏移
    let lineStartByte: number = 0;
    // 跨块保留的未处理尾巴（不含换行符）
    let pending: string = '';

    while (true) {
      const chunk: string | null = reader.readNext();
      if (chunk === null) {
        break;
      }
      let buffer: string = pending + chunk;
      while (true) {
        const nl: number = buffer.indexOf('\n');
        if (nl < 0) {
          break;
        }
        // consumed 含换行符，保证 \r\n 的两个字节都被计入
        const consumed: string = buffer.substring(0, nl + 1);
        let line: string = buffer.substring(0, nl);
        if (line.endsWith('\r')) {
          line = line.substring(0, line.length - 1);
        }
        ChapterParser.matchLine(line, lineStartByte,
          lineStartByte + reader.byteLengthOf(consumed), hitsByRule);
        lineStartByte += reader.byteLengthOf(consumed);
        buffer = buffer.substring(nl + 1);
      }
      pending = buffer;
    }

    // 处理最后一行（文件不以换行结尾）
    if (pending.length > 0) {
      let line: string = pending;
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      ChapterParser.matchLine(line, lineStartByte,
        lineStartByte + reader.byteLengthOf(pending), hitsByRule);
    }

    outcome.textLength = reader.deliveredTextLength();
    outcome.byteLength = reader.deliveredByteLength();

    let bestIndex: number = -1;
    let bestCount: number = 0;
    for (let i = 0; i < hitsByRule.length; i++) {
      if (hitsByRule[i].length > bestCount) {
        bestCount = hitsByRule[i].length;
        bestIndex = i;
      }
    }
    if (bestIndex >= 0 && bestCount >= AppConstants.MIN_CHAPTER_MARKERS) {
      outcome.ruleIndex = bestIndex;
      outcome.ruleName = HIGH_RULES[bestIndex].name;
      outcome.markers = hitsByRule[bestIndex];
    } else {
      outcome.ruleIndex = -1;
      outcome.ruleName = 'fallback';
      outcome.markers = [];
      Logger.warn(LogTag.PARSER,
        `未命中可靠分章规则(最高命中 ${bestCount} 条)，使用兜底切分`);
    }
    return outcome;
  }

  private static matchLine(
    line: string, lineStartByte: number, contentStartByte: number, hitsByRule: Marker[][]
  ): void {
    if (line.length === 0 || line.length > AppConstants.MAX_TITLE_LINE_LENGTH) {
      return;
    }
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      return;
    }
    for (let i = 0; i < HIGH_RULES.length; i++) {
      if (HIGH_RULES[i].regex.test(trimmed)) {
        const marker = new Marker();
        marker.byteOffset = lineStartByte;
        marker.contentStartOffset = contentStartByte;
        marker.title = trimmed;
        marker.level = HIGH_RULES[i].level;
        hitsByRule[i].push(marker);
        return; // 一行只归属一条规则
      }
    }
  }

  /** 第二遍：把标记点连成章节（endOffset 取下一章起点） */
  private static buildChapters(outcome: ScanOutcome): ParseResult {
    const result = new ParseResult();
    result.rule = outcome.ruleName;
    result.fallback = outcome.ruleIndex < 0;
    const unit: number = ChapterParser.bytesPerChar(outcome.textLength, outcome.byteLength);

    if (outcome.markers.length === 0) {
      ChapterParser.fillByFixedSize(result, outcome.fileSize, unit);
      return result;
    }

    const markers: Marker[] = outcome.markers;
    let chapterIndex: number = 0;

    // 首章之前若有实质内容，补一条"前言"，避免开头内容读不到
    if (markers[0].byteOffset > AppConstants.PREFACE_MIN_BYTES) {
      const preface = new ParsedChapter();
      preface.chapterIndex = 0;
      preface.title = '前言';
      preface.startOffset = 0;
      preface.endOffset = markers[0].byteOffset;
      preface.wordCount = Math.round(markers[0].byteOffset / unit);
      result.chapters.push(preface);
      chapterIndex = 1;
    }

    for (let i = 0; i < markers.length; i++) {
      const marker: Marker = markers[i];
      const chapter = new ParsedChapter();
      chapter.chapterIndex = chapterIndex;
      chapter.title = marker.title;
      chapter.level = marker.level;
      // 章节【内容】从标题行之后开始：标题已单独存进 chapter.title，
      // 不能再算进正文，否则第 1 章会把标题读成正文开头。
      chapter.startOffset = marker.contentStartOffset;
      const end: number | null = (i + 1 < markers.length) ? markers[i + 1].byteOffset : null;
      chapter.endOffset = end;
      chapter.wordCount = end === null ? 0 : Math.round((end - marker.contentStartOffset) / unit);
      result.chapters.push(chapter);
      chapterIndex++;
    }
    ChapterParser.sumWordCount(result, outcome.fileSize, unit);
    ChapterParser.markSuspiciousIfOdd(result);
    return result;
  }

  /**
   * 判据：分章结果是否"可疑"（编码大概选错了）。
   *
   * ⚠️ 这是**唯一**的判定点 —— 命中标记与兜底切分两条路径都调它。
   * 早先只在兜底分支判，于是"命中 3 条标记（刚好达到下限）、只切出 4 章"
   * 这种书一路绿灯入库，点开就是白屏假死（用户实测）。
   * 同一件事两处实现必然漏一处，所以收成一个方法。
   *
   * 判据用**平均每章字符数**而不是"章数"：
   *  - 章数少在小文件上是正常的（一本 5 万字的短篇集只有 3 章很合理）；
   *  - 而"平均一章超过 10 万字"几乎只可能是分章失败
   *    （正常网文 2000~5000 字/章，实体书也不过几万字/章）。
   *
   * 这个标记不是"拒绝导入"，而是**提示用户在入库前换编码重试**：
   * 编码错的书即使入库也读不了（单章几十万字 ⇒ 数千次分页测量 ⇒ 假死）。
   */
  private static markSuspiciousIfOdd(result: ParseResult): void {
    if (result.chapters.length === 0) {
      return;
    }
    const avgWords: number = result.totalWordCount / result.chapters.length;
    if (avgWords > AppConstants.SUSPICIOUS_AVG_CHAPTER_CHARS) {
      result.suspicious = true;
      Logger.warn(LogTag.PARSER,
        `分章可疑：仅 ${result.chapters.length} 章、平均每章约 ${Math.round(avgWords)} 字，`
          + `编码可能不正确（rule=${result.rule} fallback=${result.fallback}）`);
    }
  }

  /** 无可靠章节标记时按固定字节数切分，保证任何文件都能读 */
  private static fillByFixedSize(result: ParseResult, fileSize: number, unit: number): void {
    if (fileSize <= 0) {
      const only = new ParsedChapter();
      only.chapterIndex = 0;
      only.title = '正文';
      only.startOffset = 0;
      only.endOffset = null;
      result.chapters.push(only);
      return;
    }
    /**
     * ⚠️ `unit`（字节/字符）必须先夹到合理区间，否则会用错编码把书切成个位数章。
     *
     * `unit` 由 `StreamTextReader` 实测得出（已交付文本 / 对应字节），
     * 编码正确时：GBK/GB18030 中文约 2.0、UTF-8 中文约 3.0、纯英文约 1.0。
     * 而**编码选错**时解码会大量产出替换字符，`unit` 会被算成一个荒谬的值，
     * 于是 `8000 × unit` 变成"一章几十万字" —— 一本小说只剩 4 章。
     * 那种章节一打开就是几千次分页测量（见 `PaginationService.MAX_MEASURED_CHARS`），
     * 表现为阅读页白屏假死。
     *
     * 夹取本身不会让分章变准（编码错了内容本来就是乱的），
     * 但能保证**每章大小可控、阅读页不会假死**，同时配合 `suspicious` 提示用户换编码。
     */
    const safeUnit: number = Math.min(4, Math.max(1, unit));
    const bytesPerChapter: number = Math.max(1, Math.round(AppConstants.FALLBACK_CHARS_PER_CHAPTER * safeUnit));
    let index: number = 0;
    let offset: number = 0;
    while (offset < fileSize) {
      const chapter = new ParsedChapter();
      chapter.chapterIndex = index;
      chapter.title = `第 ${index + 1} 章`;
      chapter.startOffset = offset;
      const next: number = offset + bytesPerChapter;
      chapter.endOffset = next >= fileSize ? null : next;
      /**
       * ⚠️ 字数也必须用 `safeUnit`，与下面的 `sumWordCount` **同源**。
       * 混用（这里 raw unit、那里 safeUnit）会让"最后一章"与其它章
       * 按两套比例算字数，总字数与平均章节大小的判断就失真了 ——
       * 而这正是 `markSuspiciousIfOdd` 的输入。
       */
      chapter.wordCount = Math.round((Math.min(next, fileSize) - offset) / safeUnit);
      result.chapters.push(chapter);
      offset = next;
      index++;
    }
    // 兜底切分的结果同样要走统一的可疑判定（不要在这里各写一份判据）
    ChapterParser.sumWordCount(result, fileSize, safeUnit);
    ChapterParser.markSuspiciousIfOdd(result);
  }

  /** 最后一章没有 endOffset，用文件大小补齐并汇总总字数 */
  private static sumWordCount(result: ParseResult, fileSize: number, unit: number): void {
    let total: number = 0;
    for (let i = 0; i < result.chapters.length; i++) {
      const chapter: ParsedChapter = result.chapters[i];
      if (chapter.endOffset === null) {
        const len: number = fileSize > chapter.startOffset ? fileSize - chapter.startOffset : 0;
        chapter.wordCount = Math.round(len / unit);
      }
      total += chapter.wordCount;
    }
    result.totalWordCount = total;
  }

  private static bytesPerChar(textLength: number, byteLength: number): number {
    if (textLength <= 0 || byteLength <= 0) {
      return 1;
    }
    const unit: number = byteLength / textLength;
    return unit > 0 ? unit : 1;
  }
}
