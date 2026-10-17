/**
 * 阅读位置：与书籍格式无关的兼容层，对应 book.location 字段的 JSON 内容。
 * 详见 docs/小说阅读器设计文档.md 5.3。
 *
 * offset 语义 = 【章内解码文本的 UTF-16 代码单元下标】
 * chapterIndex = 0-based；-1 表示无进度
 *
 * ⚠️ 仅支持 TXT（EPUB 支持已放弃）：早期的 type/href/anchor/cfi 字段
 * 是为 EPUB 的 CFI 定位预留的，已随支持取消而删除。
 * JSON 里若有旧字段会被忽略（fromJson 只读本类声明的字段）。
 */
export class ReadingPosition {
  chapterIndex: number = -1;
  offset: number = 0;
  /** 跨章节的全局进度 0~1 */
  percent: number = 0;

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
      if (obj.chapterIndex !== undefined && obj.chapterIndex !== null) {
        pos.chapterIndex = obj.chapterIndex;
      }
      if (obj.offset !== undefined && obj.offset !== null) {
        pos.offset = obj.offset;
      }
      if (obj.percent !== undefined && obj.percent !== null) {
        pos.percent = obj.percent;
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
