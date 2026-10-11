import { util } from '@kit.ArkTS';
import { ByteSource } from '../../data/source/ByteSource';
import { AppConstants } from '../constants/AppConstants';
import { ByteLength } from './ByteLength';

/**
 * 流式文本读取器：分块读字节 → 增量解码 → 输出文本，并精确维护
 * "这些文本对应源文件里的哪些字节"。
 *
 * 为什么需要它：分章要把"第 N 章在文本中的位置"换算成可 seek 的**文件字节偏移**，
 * 而解码是按块进行的、多字节字符还会跨块。
 *
 * 两个关键性质：
 *  1. `util.StringDecoder` 会把末尾不完整的多字节字符留在内部缓冲，下次 write 时再交付，
 *     所以跨块残字节由它处理，调用方不需要拼字节；也正因为如此，
 *     每次 write 交付的文本一定是**完整的字符序列**；
 *  2. 于是"已交付文本占多少字节"可以按编码规则直接累加得到（见 ByteLength），
 *     不必重新编码。
 *
 * ⚠️ 不要用 `util.TextEncoder(encoding)` 反推字节数：SDK 中
 *     `TextEncoder.encoding` 声明为 `readonly encoding = 'utf-8'`，
 *     即它只做 UTF-8 编码、构造函数传入的 encoding 参数无效
 *     （`util.StringEncoder` 这个类并不存在）。用它计算 GB18030 文本的字节长度，
 *     一个汉字会被算成 3 字节（实际 2 字节），字节游标会越走越偏，分章偏移全错。
 *
 * ⚠️ 也不要用"本块字符数 × 平均字节数"回推偏移 —— 误差会逐块累积。
 */
export class StreamTextReader {
  private source: ByteSource;
  private encoding: string;
  private decoder: util.StringDecoder;

  private nextOffset: number = 0;
  private closed: boolean = false;

  /** 已交付文本的字符总数（UTF-16 代码单元） */
  private textLength: number = 0;
  /** 已交付文本对应的源字节总数 */
  private byteLength: number = 0;

  constructor(source: ByteSource, encoding: string) {
    this.source = source;
    this.encoding = encoding;
    this.decoder = new util.StringDecoder(encoding);
  }

  getEncoding(): string {
    return this.encoding;
  }

  /** 已交付文本的字符数 */
  deliveredTextLength(): number {
    return this.textLength;
  }

  /** 已交付文本对应的源字节数 = 下一次交付的起始字节位置 */
  deliveredByteLength(): number {
    return this.byteLength;
  }

  /** 每个字符的平均字节数，仅用于字数估算与兜底切分 */
  bytesPerChar(): number {
    if (this.textLength <= 0 || this.byteLength <= 0) {
      return 1;
    }
    return this.byteLength / this.textLength;
  }

  /** 是否已全部读完 */
  isFinished(): boolean {
    return this.closed;
  }

  /**
   * 读取下一块文本。返回 null 表示已到末尾（此时内部已执行解码器收尾）。
   *
   * @param chunkBytes 单次读取字节数，默认 1 MiB
   */
  readNext(chunkBytes: number = AppConstants.READ_CHUNK_BYTES): string | null {
    if (this.closed) {
      return null;
    }
    const remaining: number = this.source.size() - this.nextOffset;
    if (remaining <= 0) {
      return this.finish();
    }
    const want: number = Math.min(chunkBytes, remaining);
    const bytes: Uint8Array = this.source.readChunk(this.nextOffset, want);
    if (bytes.length === 0) {
      return this.finish();
    }
    this.nextOffset += bytes.length;

    const text: string = this.decoder.write(bytes);
    this.byteLength += ByteLength.of(text, this.encoding);
    this.textLength += text.length;
    return text;
  }

  /** 解码器收尾：返回内部缓冲里剩余的可解码文本（通常是空串） */
  private finish(): string | null {
    this.closed = true;
    const rest: string = this.decoder.end();
    if (rest.length === 0) {
      return null;
    }
    this.byteLength += ByteLength.of(rest, this.encoding);
    this.textLength += rest.length;
    return rest;
  }

  /** 单段文本在源文件中的字节长度，供上层按行推进字节游标 */
  byteLengthOf(text: string): number {
    return ByteLength.of(text, this.encoding);
  }
}
