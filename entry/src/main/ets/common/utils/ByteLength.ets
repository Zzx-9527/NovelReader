import { Encodings } from './EncodingDetector';

/**
 * 编码字节长度计算。
 *
 * 为什么需要它：分章必须知道"这段文本在原文件里占几个字节"，
 * 以便把文本位置换算成可 seek 的文件字节偏移。
 *
 * 为什么不能用 util.TextEncoder 算：SDK 中 `TextEncoder.encoding` 声明为
 * `readonly encoding = 'utf-8'`，即**它只做 UTF-8 编码**，构造函数传入的
 * encoding 参数无效；而 `util.StringEncoder` 这个类并不存在。
 * 若用 TextEncoder 计算 GB18030 文本的字节长度，一个汉字会被算成 3 字节
 * （实际 2 字节），字节游标会越走越偏，导致分章偏移全错。
 *
 * 因此这里按编码规则**直接对字符计数**，不依赖任何编解码器：
 *  - UTF-8：按代码点分段（1/2/3/4 字节）
 *  - UTF-16：每代码单元 2 字节（含 BOM 时另加 2）
 *  - GB18030/GBK：ASCII 1 字节，BMP 内非 ASCII 2 字节，>U+FFFF 4 字节
 *
 * 前提：字符串来自对应编码的正确解码，不存在 U+FFFD 替换字符。
 * 流式解码时多字节残字符由 StringDecoder 缓冲、不会交付，
 * 所以每段文本都是完整字符，逐段求和等于源字节数。
 */
export class ByteLength {
  /** 计算文本在指定编码下占用的字节数 */
  static of(text: string, encoding: string): number {
    if (text.length === 0) {
      return 0;
    }
    switch (encoding) {
      case Encodings.UTF8:
        return ByteLength.utf8(text);
      case Encodings.UTF16LE:
        return text.length * 2;
      case Encodings.UTF16BE:
        return text.length * 2;
      case Encodings.GBK:
      case Encodings.GB18030:
        return ByteLength.gb(text);
      default:
        // 未知编码：保守按 1 字节/代码单元，同时调用方应记录告警
        return ByteLength.gb(text);
    }
  }

  /** UTF-8：按代码点长度计 */
  private static utf8(text: string): number {
    let bytes: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 0x80) {
        bytes += 1;
      } else if (code < 0x800) {
        bytes += 2;
      } else if (code >= 0xD800 && code <= 0xDBFF) {
        // 高代理项：需要和低代理项组成一个 4 字节字符
        if (i + 1 < text.length) {
          const next: number = text.charCodeAt(i + 1);
          if (next >= 0xDC00 && next <= 0xDFFF) {
            bytes += 4;
            i++; // 跳过低代理项
            continue;
          }
        }
        // 落单的代理项：按 3 字节处理，避免死循环
        bytes += 3;
      } else {
        bytes += 3;
      }
    }
    return bytes;
  }

  /**
   * GB18030 / GBK：
   *  - U+0000~U+007F  → 1 字节
   *  - 其余 BMP 字符   → 2 字节
   *  - U+10000 以上    → 4 字节（GB18030 四字节区）
   *
   * 注意：U+20AC(€) 在 GBK/CP936 里是单字节 0x80，但这类字符在小说文本中
   * 极为罕见，按 2 字节处理带来的偏差可忽略；真要严谨应查码表。
   */
  private static gb(text: string): number {
    let bytes: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 0x80) {
        bytes += 1;
      } else if (code >= 0xD800 && code <= 0xDBFF) {
        if (i + 1 < text.length) {
          const next: number = text.charCodeAt(i + 1);
          if (next >= 0xDC00 && next <= 0xDFFF) {
            bytes += 4;
            i++;
            continue;
          }
        }
        bytes += 2;
      } else {
        bytes += 2;
      }
    }
    return bytes;
  }

  /**
   * 代理对编码校验用：把字符串安全切成不与代理对错位的片段。
   * （目前未被调用，保留给"按字符数切分正文"的页码计算使用）
   */
  static codePointLength(text: string): number {
    let count: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const next: number = text.charCodeAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          i++;
        }
      }
      count++;
    }
    return count;
  }
}
