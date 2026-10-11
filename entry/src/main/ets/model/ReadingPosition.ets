/**
 * 阅读位置：与书籍格式无关的兼容层，对应 book.location 字段的 JSON 内容。
 * 详见 docs/小说阅读器设计文档.md 5.3。
 *
 * offset 语义 = 【章内解码文本的 UTF-16 代码单元下标】
 * chapterIndex = 0-based；-1 表示无进度
 */
export class ReadingPosition {
  /** 'txt' | 'epub' */
  type: string = 'txt';
  chapterIndex: number = -1;
  offset: number = 0;
  /** 跨章节的全局进度 0~1 */
  percent: number = 0;

  // EPUB 用（V1.1）
  href: string = '';
  anchor: string = '';
  cfi: string = '';

  static none(): ReadingPosition {
    return new ReadingPosition();
  }

  static hasProgress(pos: ReadingPosition): boolean {
    return pos.chapterIndex >= 0;
  }

  /**
   * 安全解析：任何异常都退化为"无进度"。
   * 阅读页打开时绝不能被一条脏 JSON 打断。
   */
  static fromJson(raw: string): ReadingPosition {
    const pos = new ReadingPosition();
    if (raw === undefined || raw === null || raw.length === 0) {
      return pos;
    }
    try {
      const obj = JSON.parse(raw) as ReadingPosition;
      if (obj === null || obj === undefined) {
        return pos;
      }
      if (obj.type !== undefined && obj.type !== null) {
        pos.type = obj.type;
      }
      if (obj.chapterIndex !== undefined && obj.chapterIndex !== null) {
        pos.chapterIndex = obj.chapterIndex;
      }
      if (obj.offset !== undefined && obj.offset !== null) {
        pos.offset = obj.offset;
      }
      if (obj.percent !== undefined && obj.percent !== null) {
        pos.percent = obj.percent;
      }
      if (obj.href !== undefined && obj.href !== null) {
        pos.href = obj.href;
      }
      if (obj.anchor !== undefined && obj.anchor !== null) {
        pos.anchor = obj.anchor;
      }
      if (obj.cfi !== undefined && obj.cfi !== null) {
        pos.cfi = obj.cfi;
      }
    } catch (e) {
      return new ReadingPosition();
    }
    return pos;
  }

  toJson(): string {
    return JSON.stringify(this);
  }
}
