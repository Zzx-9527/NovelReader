import { util } from '@kit.ArkTS';
import { ByteSource } from '../source/ByteSource';
import { ChapterCache } from '../../common/utils/ChapterCache';
import { AppConstants, LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';

/**
 * 章节正文读取服务：按【文件字节偏移】精确取出某一章并解码成字符串。
 *
 * 为什么需要它：章节正文不存数据库（只存字节偏移），
 * 阅读时必须能从原文件 seek 出指定章节，且不能把整本书读进内存。
 *
 * 生命周期由 ViewModel 管理（不用全局单例）：
 *   const svc = new ChapterReadService(source, encoding);
 *   const text = svc.decodeChapter(chapter);
 *   svc.dispose();   // 关闭底层文件
 */
export class ChapterReadService {
  private source: ByteSource;
  private encoding: string;
  /** 缓存 key 必须带 bookId，否则换书时会命中旧内容 */
  private bookId: number;
  private cache: ChapterCache = new ChapterCache();
  private disposed: boolean = false;

  constructor(source: ByteSource, encoding: string, bookId: number = 0) {
    this.source = source;
    this.encoding = encoding;
    this.bookId = bookId;
  }

  getCacheSize(): number {
    return this.cache.size();
  }

  /**
   * 解码一章正文。
   *
   * @param startOffset 起始字节偏移
   * @param endOffset   结束字节偏移（不含）；null 表示到文件末尾
   * @param maxBytes    单次解码上限，null 用默认值。
   *                    有了它，"最后一章"也不会把整个文件读进内存。
   */
  decodeChapter(
    startOffset: number, endOffset: number | null, maxBytes: number | null = null
  ): string {
    if (this.disposed) {
      return '';
    }
    const limit: number = maxBytes === null ? AppConstants.DEFAULT_CHAPTER_MAX_BYTES : maxBytes;
    const endKey: string = endOffset === null ? 'eof' : `${endOffset}`;
    // key 前缀带 bookId：换书/重建服务后不会误命中旧书内容
    const cacheKey: string = `${this.bookId}_${startOffset}_${endKey}_${limit}`;

    const cached: string | null = this.cache.get(cacheKey);
    if (cached !== null) {
      return cached;
    }

    const fileSize: number = this.source.size();
    if (startOffset < 0 || startOffset >= fileSize) {
      return '';
    }
    let stop: number = endOffset === null ? fileSize : Math.min(endOffset, fileSize);
    if (stop <= startOffset) {
      return '';
    }
    if (stop - startOffset > limit) {
      stop = startOffset + limit;
    }

    let text: string = '';
    try {
      text = this.readAndDecode(startOffset, stop);
    } catch (e) {
      Logger.error(LogTag.READ, `解码章节失败 offset=${startOffset}: ${Logger.errText(e as Object)}`);
      return '';
    }
    this.cache.put(cacheKey, text);
    return text;
  }

  /** 分块读取并用 StringDecoder 增量解码（它会处理跨块残字节） */
  private readAndDecode(start: number, stop: number): string {
    const decoder = new util.StringDecoder(this.encoding);
    const pieces: string[] = [];
    let cursor: number = start;
    while (cursor < stop) {
      const want: number = Math.min(AppConstants.READ_CHUNK_BYTES, stop - cursor);
      const bytes: Uint8Array = this.source.readChunk(cursor, want);
      if (bytes.length === 0) {
        break;
      }
      pieces.push(decoder.write(bytes));
      cursor += bytes.length;
    }
    pieces.push(decoder.end());
    return pieces.join('');
  }

  /** 清空缓存（换字号重排等场景不需要，但重新分章后必须清） */
  clearCache(): void {
    this.cache.clear();
  }

  /** 释放底层文件句柄。ViewModel 的 aboutToDisappear 必须调用。 */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.cache.clear();
    this.source.close();
  }
}
