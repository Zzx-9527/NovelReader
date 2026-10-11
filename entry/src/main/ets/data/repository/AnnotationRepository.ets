import { relationalStore } from '@kit.ArkData';
import { RdbHelper } from '../database/RdbHelper';
import { Annotation } from '../../model/Annotation';
import { AnnotationCol, DbConstants } from '../../common/constants/DbConstants';
import { AppConstants } from '../../common/constants/AppConstants';
import { ChapterRepository } from './ChapterRepository';

const db = (): RdbHelper => RdbHelper.getInstance();

/**
 * 书签 / 划线 / 笔记仓储。
 *
 * 重要约束：book_id 与 chapter_index 是【查询冗余列】，真相在 chapter_id。
 * 因此新增标注时必须经由本类查 chapter 填充冗余列 ——
 * 业务层自己拼 INSERT 会让三处不一致，书签在目录里串章。
 */
export class AnnotationRepository {
  // ------------------------------------------------------------ 查询

  /**
   * 某本书的标注列表。
   * @param type 传 AppConstants.ANNOTATION_ALL(0) 表示不限类型
   */
  static async listByBook(bookId: number, type: number): Promise<Annotation[]> {
    let sql: string =
      `SELECT ${AnnotationCol.ALL} FROM ${DbConstants.TABLE_ANNOTATION} ` +
      `WHERE book_id = ? AND deleted = 0`;
    const args: Array<relationalStore.ValueType> = [bookId];
    if (type !== AppConstants.ANNOTATION_ALL) {
      sql += ` AND type = ?`;
      args.push(type);
    }
    sql += ` ORDER BY chapter_index ASC, start_offset ASC`;
    const list: Annotation[] = [];
    await db().query(sql, args, (rs: relationalStore.ResultSet) => {
      list.push(AnnotationRepository.mapRow(rs));
    });
    return list;
  }

  static async listByChapter(bookId: number, chapterIndex: number): Promise<Annotation[]> {
    const list: Annotation[] = [];
    await db().query(
      `SELECT ${AnnotationCol.ALL} FROM ${DbConstants.TABLE_ANNOTATION} ` +
      `WHERE book_id = ? AND chapter_index = ? AND deleted = 0 ORDER BY start_offset ASC`,
      [bookId, chapterIndex],
      (rs: relationalStore.ResultSet) => {
        list.push(AnnotationRepository.mapRow(rs));
      });
    return list;
  }

  static async getById(annotationId: number): Promise<Annotation | null> {
    let annotation: Annotation | null = null;
    await db().queryFirst(
      `SELECT ${AnnotationCol.ALL} FROM ${DbConstants.TABLE_ANNOTATION} WHERE id = ?`,
      [annotationId],
      (rs: relationalStore.ResultSet) => {
        annotation = AnnotationRepository.mapRow(rs);
      });
    return annotation;
  }

  static async countByBook(bookId: number, type: number): Promise<number> {
    let sql: string =
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_ANNOTATION} WHERE book_id = ? AND deleted = 0`;
    const args: Array<relationalStore.ValueType> = [bookId];
    if (type !== AppConstants.ANNOTATION_ALL) {
      sql += ` AND type = ?`;
      args.push(type);
    }
    return db().queryNumber(sql, args, 0);
  }

  // ------------------------------------------------------------ 写入

  /**
   * 新增标注。冗余列由 chapter_id 反查填充。
   *
   * ⚠️ 与 BookRepository.insert 同样的原因，这里用 typed `insert()` 直接拿 rowId，
   * 不能用 `executeSql` + 回查主键 —— 事务内 `querySql` 读不到刚写入的行。
   * 当前调用点虽然在事务外，但这类"写完立刻回查"的写法是隐患，一律不要。
   *
   * @param startOffset 章内 UTF-16 下标；书签可传 null 表示只记章首
   * @returns 新增的标注 id；找不到对应章节时返回 0 且不写入
   */
  static async add(
    bookId: number, chapterIndex: number, type: number,
    startOffset: number | null, endOffset: number | null,
    selectedText: string, noteContent: string, color: string
  ): Promise<number> {
    await RdbHelper.ensureReady();
    const chapter = await ChapterRepository.getByIndex(bookId, chapterIndex);
    if (chapter === null) {
      return 0;
    }
    const now: number = Date.now();
    const bucket: relationalStore.ValuesBucket = {
      'book_id': bookId,
      'chapter_id': chapter.id,
      'chapter_index': chapterIndex,
      'start_offset': startOffset,
      'end_offset': endOffset,
      'selected_text': selectedText,
      'note_content': noteContent,
      'type': type,
      'color': color,
      'created_at': now,
      'updated_at': now,
      'deleted': 0
    };
    return db().getStore().insert(DbConstants.TABLE_ANNOTATION, bucket);
  }

  /** 加书签：只记章首位置 */
  static async addBookmark(bookId: number, chapterIndex: number, offset: number | null): Promise<number> {
    return AnnotationRepository.add(bookId, chapterIndex,
      AppConstants.ANNOTATION_BOOKMARK, offset, null, '', '', '');
  }

  /** 加划线 */
  static async addHighlight(
    bookId: number, chapterIndex: number, startOffset: number, endOffset: number,
    selectedText: string, color: string
  ): Promise<number> {
    return AnnotationRepository.add(bookId, chapterIndex,
      AppConstants.ANNOTATION_HIGHLIGHT, startOffset, endOffset, selectedText, '', color);
  }

  /** 加笔记（带选文） */
  static async addNote(
    bookId: number, chapterIndex: number, startOffset: number, endOffset: number,
    selectedText: string, noteContent: string, color: string
  ): Promise<number> {
    return AnnotationRepository.add(bookId, chapterIndex,
      AppConstants.ANNOTATION_NOTE, startOffset, endOffset, selectedText, noteContent, color);
  }

  static async updateNote(annotationId: number, noteContent: string, color: string): Promise<void> {
    await RdbHelper.ensureReady();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_ANNOTATION} SET note_content = ?, color = ?, updated_at = ? WHERE id = ?`,
      [noteContent, color, Date.now(), annotationId]);
  }

  static async softDelete(annotationId: number): Promise<void> {
    await RdbHelper.ensureReady();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_ANNOTATION} SET deleted = 1, updated_at = ? WHERE id = ?`,
      [Date.now(), annotationId]);
  }

  /** 导出用：某本书全部标注（不含已删除） */
  static async listAllForExport(bookId: number): Promise<Annotation[]> {
    return AnnotationRepository.listByBook(bookId, AppConstants.ANNOTATION_ALL);
  }

  // ------------------------------------------------------------ 映射

  private static mapRow(rs: relationalStore.ResultSet): Annotation {
    const a = new Annotation();
    a.id = rs.getLong(rs.getColumnIndex(AnnotationCol.ID));
    a.bookId = rs.getLong(rs.getColumnIndex(AnnotationCol.BOOK_ID));
    a.chapterId = rs.getLong(rs.getColumnIndex(AnnotationCol.CHAPTER_ID));
    a.chapterIndex = rs.getLong(rs.getColumnIndex(AnnotationCol.CHAPTER_INDEX));

    const startIdx: number = rs.getColumnIndex(AnnotationCol.START_OFFSET);
    a.startOffset = rs.isColumnNull(startIdx) ? null : rs.getLong(startIdx);
    const endIdx: number = rs.getColumnIndex(AnnotationCol.END_OFFSET);
    a.endOffset = rs.isColumnNull(endIdx) ? null : rs.getLong(endIdx);

    a.selectedText = rs.getString(rs.getColumnIndex(AnnotationCol.SELECTED_TEXT));
    a.noteContent = rs.getString(rs.getColumnIndex(AnnotationCol.NOTE_CONTENT));
    a.type = rs.getLong(rs.getColumnIndex(AnnotationCol.TYPE));
    a.color = rs.getString(rs.getColumnIndex(AnnotationCol.COLOR));
    a.createdAt = rs.getLong(rs.getColumnIndex(AnnotationCol.CREATED_AT));
    a.updatedAt = rs.getLong(rs.getColumnIndex(AnnotationCol.UPDATED_AT));
    a.deleted = rs.getLong(rs.getColumnIndex(AnnotationCol.DELETED));
    return a;
  }
}
