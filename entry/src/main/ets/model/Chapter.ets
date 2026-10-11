import { DbConstants } from '../common/constants/DbConstants';

/**
 * 章节（纯数据）。
 *
 * startOffset / endOffset 是【原文件字节偏移】，用于 fs.read 随机 seek；
 * chapterIndex 是 0-based。
 */
export class Chapter {
  id: number = 0;
  bookId: number = 0;
  title: string = '';
  /** 原文件字节偏移（含） */
  startOffset: number = 0;
  /** 原文件字节偏移（不含）；null 表示到文件末尾 */
  endOffset: number | null = null;
  /** EPUB 章节文件路径 */
  href: string = '';
  /** EPUB 章内锚点 */
  anchor: string = '';
  /** 0 = 章，1 = 卷 */
  level: number = 0;
  wordCount: number = 0;
  chapterIndex: number = 0;
  createdAt: number = 0;
  updatedAt: number = 0;

  /** 该章在文件中的字节长度；endOffset 为空时由调用方传 fileSize 兜底 */
  byteLength(fileSize: number): number {
    if (this.endOffset === null) {
      return fileSize > this.startOffset ? fileSize - this.startOffset : 0;
    }
    return this.endOffset - this.startOffset;
  }

  /** 是否为卷/篇一级 */
  isVolume(): boolean {
    return this.level > 0;
  }

  /** 目录显示用的序号（0-based 内部，1-based 展示） */
  displayNumber(): number {
    return this.chapterIndex + 1;
  }

  static empty(): Chapter {
    const c = new Chapter();
    c.chapterIndex = DbConstants.NO_PROGRESS;
    return c;
  }
}
