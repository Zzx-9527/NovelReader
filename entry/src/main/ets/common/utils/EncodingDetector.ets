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

    // 2) UTF-16 无 BOM 的情况：靠"空字节奇偶性"判断。
    //    这一步必须在多编码打分之前 —— 否则 GBK 文本按 utf-16le 解码时，
    //    大量字节对会落进 CJK 区间（U+4E00~U+9FFF），让 UTF-16 得分虚高，
    //    反而压过正确的 GB18030。
    const parity: number = EncodingDetector.nullParity(sample);
    if (parity > 0) {
      result.encoding = Encodings.UTF16LE;
      result.confidence = Confidence.MEDIUM;
      return result;
    }
    if (parity < 0) {
      result.encoding = Encodings.UTF16BE;
      result.confidence = Confidence.MEDIUM;
      return result;
    }

    // 3) UTF-8 合法性校验：无任何非法序列即认为是 UTF-8
    const utf8Probe: EncodingScore = EncodingDetector.probe(Encodings.UTF8, sample);
    result.candidates.push(utf8Probe);
    if (utf8Probe.replacementRatio === 0) {
      result.encoding = Encodings.UTF8;
      result.confidence = Confidence.HIGH;
      return result;
    }

    // 4) 中文编码对照打分
    const gbProbe: EncodingScore = EncodingDetector.probe(Encodings.GB18030, sample);
    const big5Probe: EncodingScore = EncodingDetector.probe(Encodings.BIG5, sample);
    result.candidates.push(gbProbe);
    result.candidates.push(big5Probe);

    const all: EncodingScore[] = [gbProbe, big5Probe];
    let best: EncodingScore = all[0];
    for (const c of all) {
      if (c.score > best.score) {
        best = c;
      }
    }
    result.encoding = best.encoding;

    // 与次优分数太接近说明不可靠，交给用户确认
    let second: number = 0;
    for (const c of all) {
      if (c.encoding !== best.encoding && c.score > second) {
        second = c.score;
      }
    }
    result.confidence = (best.score - second) >= 0.15 ? Confidence.MEDIUM : Confidence.LOW;
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

  /** 用指定编码解码样本并打分 */
  private static probe(encoding: string, sample: Uint8Array): EncodingScore {
    const out = new EncodingScore();
    out.encoding = encoding;
    try {
      const decoder = new util.StringDecoder(encoding);
      const text: string = decoder.end(sample);
      out.replacementRatio = EncodingDetector.replacementRatio(text);
      out.score = EncodingDetector.cjkScore(text, out.replacementRatio);
    } catch (e) {
      out.score = -1;
      out.replacementRatio = 1;
      Logger.debug(LogTag.ENCODING, `编码 ${encoding} 探测异常`);
    }
    return out;
  }

  /** 替换字符与控制字符占比：越低越可能是正确编码 */
  private static replacementRatio(text: string): number {
    if (text.length === 0) {
      return 1;
    }
    let bad: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code === 0xFFFD) {
        bad++;
      } else if (code < 0x09 || (code > 0x0D && code < 0x20 && code !== 0x1B)) {
        // 换行/制表/回车之外的控制字符：明显是解码错误的信号
        bad++;
      }
    }
    return bad / text.length;
  }

  /** 中文文本得分：CJK 占比减去替换字符惩罚 */
  private static cjkScore(text: string, replacementRatio: number): number {
    if (text.length === 0) {
      return -1;
    }
    let cjk: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) {
        cjk++;
      }
    }
    return (cjk / text.length) - replacementRatio * 3;
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
