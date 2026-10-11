import { util } from '@kit.ArkTS';
import { AppConstants, LogTag } from '../constants/AppConstants';
import { Logger } from './Logger';
import { ByteSource } from '../../data/source/ByteSource';

/** 探测置信度 */
export enum Confidence {
  HIGH = 2,
  MEDIUM = 1,
  LOW = 0
}

/** 一种候选编码的打分 */
export class EncodingScore {
  encoding: string = '';
  score: number = 0;
  replacementRatio: number = 1;
}

export class DetectionResult {
  encoding: string = 'utf-8';
  confidence: Confidence = Confidence.LOW;
  candidates: EncodingScore[] = [];

  /** 置信度低时，UI 应引导用户手动选择编码 */
  needsUserConfirm(): boolean {
    return this.confidence === Confidence.LOW;
  }
}

/** 编码名常量 */
export class Encodings {
  static readonly UTF8: string = 'utf-8';
  static readonly GBK: string = 'gbk';
  static readonly GB18030: string = 'gb18030';
  static readonly BIG5: string = 'big5';
  static readonly UTF16LE: string = 'utf-16le';
  static readonly UTF16BE: string = 'utf-16be';

  /** 导入确认页的可选项，按使用频率排序 */
  static readonly ALL: string[] = [
    Encodings.UTF8, Encodings.GB18030, Encodings.GBK,
    Encodings.BIG5, Encodings.UTF16LE, Encodings.UTF16BE
  ];
}

/**
 * 编码探测与解码。
 *
 * 重要结论（依据本机 SDK @ohos.util.d.ts）：
 *  - `util.TextDecoder` 只覆盖 utf-8 / utf-16 / iso-8859 / windows-1251，【不含 GBK】；
 *  - `util.StringDecoder` 明确支持 gbk / gb18030 / big5 / utf-16be / utf-16le 等，
 *    且 write() 自动缓存跨块不完整的多字节字符。
 *  => 所以 TXT 导入全程使用 StringDecoder；GB18030 优先于 GBK（超集，能覆盖生僻字）。
 */
export class EncodingDetector {
  /**
   * 接受某编码所需的"可读文本占比"下限。
   *
   * 取 0.98 而非 1.0：给极少量生僻字/异体字留余量，
   * 但足以挡掉"用 UTF-16 解 GBK 字节"这类大面积乱码（那种情况占比会远低于此）。
   */
  static readonly READABLE_THRESHOLD: number = 0.98;

  /** 从 ByteSource 取样探测 */
  static detect(source: ByteSource): DetectionResult {
    const sampleLength: number = Math.min(AppConstants.ENCODING_SAMPLE_BYTES, source.size());
    if (sampleLength <= 0) {
      const empty = new DetectionResult();
      empty.encoding = Encodings.UTF8;
      empty.confidence = Confidence.LOW;
      return empty;
    }
    const sample: Uint8Array = source.readRange(0, sampleLength);
    return EncodingDetector.detectFromBytes(sample);
  }

  static detectFromBytes(sample: Uint8Array): DetectionResult {
    const result = new DetectionResult();

    // 1) BOM：置信度最高
    if (sample.length >= 3 && sample[0] === 0xEF && sample[1] === 0xBB && sample[2] === 0xBF) {
      result.encoding = Encodings.UTF8;
      result.confidence = Confidence.HIGH;
      return result;
    }
    if (sample.length >= 2 && sample[0] === 0xFF && sample[1] === 0xFE) {
      result.encoding = Encodings.UTF16LE;
      result.confidence = Confidence.HIGH;
      return result;
    }
    if (sample.length >= 2 && sample[0] === 0xFE && sample[1] === 0xFF) {
      result.encoding = Encodings.UTF16BE;
      result.confidence = Confidence.HIGH;
      return result;
    }
    if (sample.length === 0) {
      result.encoding = Encodings.UTF8;
      result.confidence = Confidence.LOW;
      return result;
    }

    // 2) 按优先级逐个候选：**必须通过"解出来是可读文本"的校验**才采纳。
    //
    //    之前的实现只做了"BOM / 空字节奇偶性 / UTF-8 是否合法"，
    //    从不校验候选编码解出来是否真的是文本 —— 结果 GBK 文件被判成 UTF-16BE，
    //    正文全成乱码（因为用 UTF-16 解 GBK 时大量字节对会落进 CJK 区，得分虚高）。
    //
    //    现在改成：候选 → 试解码 → 校验 → 通过才止步。
    const candidates: string[] = [];
    const nullParity: number = EncodingDetector.nullParity(sample);
    if (nullParity > 0) {
      candidates.push(Encodings.UTF16LE);
    } else if (nullParity < 0) {
      candidates.push(Encodings.UTF16BE);
    }
    candidates.push(Encodings.UTF8);
    candidates.push(Encodings.GB18030);
    candidates.push(Encodings.BIG5);
    // UTF-16 排在最后兜底：无 BOM 且不含空字节时，它几乎不可能是正确答案
    candidates.push(Encodings.UTF16LE);
    candidates.push(Encodings.UTF16BE);

    for (const encoding of candidates) {
      const probe: EncodingScore = EncodingDetector.probe(encoding, sample);
      result.candidates.push(probe);
      if (probe.score >= EncodingDetector.READABLE_THRESHOLD) {
        result.encoding = encoding;
        // 有明显前导空字节特征时给 MEDIUM，否则 HIGH
        result.confidence = (encoding === Encodings.UTF16LE || encoding === Encodings.UTF16BE)
          ? Confidence.MEDIUM
          : Confidence.HIGH;
        return result;
      }
    }

    // 3) 没有完全合格的候选：取分数最高者，但标记为低置信度，交由用户手选
    let best: EncodingScore = result.candidates[0];
    for (const probe of result.candidates) {
      if (probe.score > best.score) {
        best = probe;
      }
    }
    result.encoding = best.encoding;
    result.confidence = Confidence.LOW;

    // 与次优分数太接近也说明不可靠
    let second: number = -1;
    for (const probe of result.candidates) {
      if (probe.encoding !== best.encoding && probe.score > second) {
        second = probe.score;
      }
    }
    if (best.score - second >= 0.35) {
      result.confidence = Confidence.MEDIUM;
    }
    return result;
  }

  /**
   * 判断样本是否像 UTF-16：看空字节是否集中在同一个奇偶位置。
   *
   * @returns 1 = 偶数位多为空（utf-16le）; -1 = 奇数位多为空（utf-16be）; 0 = 不像 UTF-16
   *
   * 判据取样本前 512 字节即可，且要求"优势明显"才下结论 ——
   * 普通单字节文本里偶尔出现 0x00 不应该被误判成 UTF-16。
   */
  private static nullParity(sample: Uint8Array): number {
    const scanLength: number = Math.min(512, sample.length);
    if (scanLength < 16) {
      return 0;
    }
    let nullAtEven: number = 0;
    let nullAtOdd: number = 0;
    let evenSlots: number = 0;
    let oddSlots: number = 0;
    for (let i = 0; i < scanLength; i++) {
      const isNull: boolean = sample[i] === 0x00;
      if (i % 2 === 0) {
        evenSlots++;
        if (isNull) {
          nullAtEven++;
        }
      } else {
        oddSlots++;
        if (isNull) {
          nullAtOdd++;
        }
      }
    }
    const evenRatio: number = evenSlots > 0 ? nullAtEven / evenSlots : 0;
    const oddRatio: number = oddSlots > 0 ? nullAtOdd / oddSlots : 0;
    const THRESHOLD: number = 0.3;
    if (evenRatio >= THRESHOLD && evenRatio >= oddRatio * 2) {
      return 1;
    }
    if (oddRatio >= THRESHOLD && oddRatio >= evenRatio * 2) {
      return -1;
    }
    return 0;
  }

  /**
   * 可读文本占比：**这是判定编码是否正确的核心指标**。
   *
   * 什么算"可读"：
   *  - 换行 / 制表 / 回车；
   *  - 可打印 ASCII（0x20~0x7E）；
   *  - CJK 及常见中文标点（见 isReadableCjk）。
   * 什么算"不可读"：替换字符 U+FFFD、其它控制字符、私用区、以及
   * 用错误编码解出来时大量出现的无意义符号。
   *
   * 返回 0~1：越接近 1 越像正确编码。
   */
  private static readableRatio(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    let readable: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code === 0x0A || code === 0x0D || code === 0x09) {
        readable++;
      } else if (code >= 0x20 && code <= 0x7E) {
        readable++;
      } else if (EncodingDetector.isReadableCjk(code)) {
        readable++;
      }
    }
    return readable / text.length;
  }

  /** CJK 汉字、中文标点、全角符号、常用符号区 */
  private static isReadableCjk(code: number): boolean {
    // CJK 统一表意文字
    if (code >= 0x4E00 && code <= 0x9FFF) {
      return true;
    }
    // CJK 扩展 A
    if (code >= 0x3400 && code <= 0x4DBF) {
      return true;
    }
    // 中文标点、全角形式、CJK 符号
    if (code >= 0x3000 && code <= 0x303F) {
      return true;
    }
    if (code >= 0xFF00 && code <= 0xFFEF) {
      return true;
    }
    // 常用印刷符号：破折号、省略号、引号等
    if (code >= 0x2010 && code <= 0x203B) {
      return true;
    }
    if (code >= 0x2018 && code <= 0x201F) {
      return true;
    }
    // 拉丁扩展（带音标的外文名）
    if (code >= 0x00C0 && code <= 0x024F) {
      return true;
    }
    // 希腊/西里尔字母（少量出现属正常）
    if (code >= 0x0370 && code <= 0x04FF) {
      return true;
    }
    // 日文假名 / 韩文（多语言文本）
    if (code >= 0x3040 && code <= 0x30FF) {
      return true;
    }
    if (code >= 0xAC00 && code <= 0xD7AF) {
      return true;
    }
    return false;
  }

  /**
   * 探测某个编码是否"像正确编码"。
   * score = 可读占比；同时记录替换字符占比供诊断。
   */
  private static probe(encoding: string, sample: Uint8Array): EncodingScore {
    const out = new EncodingScore();
    out.encoding = encoding;
    try {
      const decoder = new util.StringDecoder(encoding);
      const text: string = decoder.end(sample);
      out.score = EncodingDetector.readableRatio(text);
      out.replacementRatio = 1 - out.score;
    } catch (e) {
      out.score = 0;
      out.replacementRatio = 1;
      Logger.debug(LogTag.ENCODING, `编码 ${encoding} 探测异常`);
    }
    return out;
  }

  /** 把用户可见的编码名归一化成 StringDecoder 接受的写法 */
  static normalizeEncoding(encoding: string): string {
    const lower: string = encoding.toLowerCase().replace('_', '-');
    if (lower === 'utf8' || lower === 'utf-8') {
      return Encodings.UTF8;
    }
    if (lower === 'gb2312' || lower === 'gbk') {
      return Encodings.GBK;
    }
    if (lower === 'gb18030') {
      return Encodings.GB18030;
    }
    if (lower === 'big5') {
      return Encodings.BIG5;
    }
    if (lower === 'utf-16le' || lower === 'utf16le') {
      return Encodings.UTF16LE;
    }
    if (lower === 'utf-16be' || lower === 'utf16be') {
      return Encodings.UTF16BE;
    }
    return lower;
  }

  /** 导入确认页预览用：整段解码 */
  static decodeAll(bytes: Uint8Array, encoding: string): string {
    try {
      const decoder = new util.StringDecoder(encoding);
      return decoder.end(bytes);
    } catch (e) {
      return '';
    }
  }
}
