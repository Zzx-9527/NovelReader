import { AppConstants } from '../common/constants/AppConstants';

/**
 * 书签 / 划线 / 笔记（纯数据）。
 *
 * bookId 与 chapterIndex 是【查询冗余列】，真相在 chapterId ——
 * 写入必须由 AnnotationRepository 统一填充，禁止业务层手写 INSERT。
 *
 * startOffset / endOffset = 章内 UTF-16 下标。
 */
export class Annotation {
  id: number = 0;
  bookId: number = 0;
  /** 外键真相 */
  chapterId: number = 0;
  /** 0-based，冗余列，供目录聚合与排序 */
  chapterIndex: number = 0;
  /** 书签允许为 null（只记章首位置） */
  startOffset: number | null = null;
  endOffset: number | null = null;
  selectedText: string = '';
  noteContent: string = '';
  type: number = AppConstants.ANNOTATION_BOOKMARK;
  color: string = '';
  createdAt: number = 0;
  updatedAt: number = 0;
  deleted: number = 0;

  isBookmark(): boolean {
    return this.type === AppConstants.ANNOTATION_BOOKMARK;
  }

  isHighlight(): boolean {
    return this.type === AppConstants.ANNOTATION_HIGHLIGHT;
  }

  isNote(): boolean {
    return this.type === AppConstants.ANNOTATION_NOTE;
  }

  hasNoteContent(): boolean {
    return this.noteContent.length > 0;
  }

  /** 是否只记了章首位置（没有具体字符区间） */
  isChapterOnly(): boolean {
    return this.startOffset === null || this.endOffset === null;
  }
}
