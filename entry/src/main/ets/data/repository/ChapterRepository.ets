import { relationalStore } from '@kit.ArkData';
import { RdbHelper } from '../database/RdbHelper';
import { Chapter } from '../../model/Chapter';
import { ChapterCol, DbConstants } from '../../common/constants/DbConstants';
import { AppConstants } from '../../common/constants/AppConstants';

const db = (): RdbHelper => RdbHelper.getInstance();

/**
 * 章节仓储。
 *
 * 注意两个映射函数不要混用（见 mapSummaryRow 的注释）。
 */
export class ChapterRepository {
  // ------------------------------------------------------------ 查询

  /** 目录列表。只查目录需要的列，避免把 href 等大字段拖进内存 */
  static async listByBook(bookId: number): Promise<Chapter[]> {
    const list: Chapter[] = [];
    await db().query(
      `SELECT ${ChapterCol.SUMMARY} FROM ${DbConstants.TABLE_CHAPTER} ` +
      `WHERE book_id = ? ORDER BY chapter_index ASC`,
      [bookId],
      (rs: relationalStore.ResultSet) => {
        list.push(ChapterRepository.mapSummaryRow(rs));
      });
    return list;
  }

  static async getByIndex(bookId: number, chapterIndex: number): Promise<Chapter | null> {
    let chapter: Chapter | null = null;
    await db().queryFirst(
      `SELECT ${ChapterCol.ALL} FROM ${DbConstants.TABLE_CHAPTER} ` +
      `WHERE book_id = ? AND chapter_index = ?`,
      [bookId, chapterIndex],
      (rs: relationalStore.ResultSet) => {
        chapter = ChapterRepository.mapFullRow(rs);
      });
    return chapter;
  }

  /**
   * 上一章 / 下一章。用 MIN/MAX 直接查，不把整本目录拉进内存。
   * @returns 相邻章序号；不存在返回 -1
   */
  static async getAdjacentIndex(
    bookId: number, chapterIndex: number, forward: boolean
  ): Promise<number> {
    const sql: string = forward
      ? `SELECT MIN(chapter_index) FROM ${DbConstants.TABLE_CHAPTER} WHERE book_id = ? AND chapter_index > ?`
      : `SELECT MAX(chapter_index) FROM ${DbConstants.TABLE_CHAPTER} WHERE book_id = ? AND chapter_index < ?`;
    return db().queryNumber(sql, [bookId, chapterIndex], -1);
  }

  static async countByBook(bookId: number): Promise<number> {
    return db().queryNumber(
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_CHAPTER} WHERE book_id = ?`, [bookId], 0);
  }

  /** 目录内按标题搜索 */
  static async searchByTitle(bookId: number, keyword: string): Promise<Chapter[]> {
    const list: Chapter[] = [];
    await db().query(
      `SELECT ${ChapterCol.SUMMARY} FROM ${DbConstants.TABLE_CHAPTER} ` +
      `WHERE book_id = ? AND title LIKE ? ORDER BY chapter_index ASC`,
      [bookId, `%${keyword}%`],
      (rs: relationalStore.ResultSet) => {
        list.push(ChapterRepository.mapSummaryRow(rs));
      });
    return list;
  }

  // ------------------------------------------------------------ 写入

  /**
   * 批量写入章节。
   *
   * 必须在事务内调用（由 ImportService 包住）：一章一行、一本书几千章时，
   * 逐条 insert 会非常慢；这里每 CHAPTER_BATCH_SIZE 条拼成一条多值 INSERT。
   */
  static async insertBatch(bookId: number, chapters: Chapter[]): Promise<void> {
    if (chapters.length === 0) {
      return;
    }
    const store = db().getStore();
    const now: number = Date.now();
    const batchSize: number = AppConstants.CHAPTER_BATCH_SIZE;

    for (let start = 0; start < chapters.length; start += batchSize) {
      const end: number = Math.min(start + batchSize, chapters.length);
      const placeholders: string[] = [];
      const args: Array<relationalStore.ValueType> = [];
      for (let i = start; i < end; i++) {
        const c: Chapter = chapters[i];
        placeholders.push('(?,?,?,?,?,?,?,?,?,?)');
        args.push(bookId);
        args.push(c.title);
        args.push(c.startOffset);
        args.push(c.endOffset);
        args.push(c.href);
        args.push(c.anchor);
        args.push(c.level);
        args.push(c.wordCount);
        args.push(c.chapterIndex);
        args.push(now);
      }
      const sql: string =
        `INSERT OR REPLACE INTO ${DbConstants.TABLE_CHAPTER} (` +
        `book_id, title, start_offset, end_offset, href, anchor, level, word_count, chapter_index, created_at` +
        `) VALUES ${placeholders.join(',')}`;
      await store.executeSql(sql, args);
    }
  }

  /**
   * 清空某本书的章节。
   *
   * ⚠️ 会因外键 CASCADE 连带删除该书全部 annotation（书签/划线/笔记）。
   * 调用方（重新分章流程）必须先向用户确认。
   */
  static async deleteByBook(bookId: number): Promise<void> {
    await db().getStore().executeSql(
      `DELETE FROM ${DbConstants.TABLE_CHAPTER} WHERE book_id = ?`, [bookId]);
  }

  /** 重新分章前统计会受影响的标注数量，用于提示用户 */
  static async countAnnotationsImpacted(bookId: number): Promise<number> {
    return db().queryNumber(
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_ANNOTATION} WHERE book_id = ? AND deleted = 0`,
      [bookId], 0);
  }

  static async updateTitle(chapterId: number, title: string): Promise<void> {
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_CHAPTER} SET title = ?, updated_at = ? WHERE id = ?`,
      [title, Date.now(), chapterId]);
  }

  // ------------------------------------------------------------ 映射

  /**
   * 目录用的轻量映射：只读 listByBook 实际 SELECT 的列。
   *
   * ⚠️ 不要拿来读 href / anchor / created_at / updated_at ——
   * 那些列不在结果集里，ResultSet.getColumnIndex 会因找不到列而抛错。
   */
  private static mapSummaryRow(rs: relationalStore.ResultSet): Chapter {
    const chapter = new Chapter();
    chapter.id = rs.getLong(rs.getColumnIndex(ChapterCol.ID));
    chapter.bookId = rs.getLong(rs.getColumnIndex(ChapterCol.BOOK_ID));
    chapter.title = rs.getString(rs.getColumnIndex(ChapterCol.TITLE));

    const startIdx: number = rs.getColumnIndex(ChapterCol.START_OFFSET);
    chapter.startOffset = rs.isColumnNull(startIdx) ? 0 : rs.getLong(startIdx);
    const endIdx: number = rs.getColumnIndex(ChapterCol.END_OFFSET);
    chapter.endOffset = rs.isColumnNull(endIdx) ? null : rs.getLong(endIdx);

    chapter.level = rs.getLong(rs.getColumnIndex(ChapterCol.LEVEL));
    chapter.wordCount = rs.getLong(rs.getColumnIndex(ChapterCol.WORD_COUNT));
    chapter.chapterIndex = rs.getLong(rs.getColumnIndex(ChapterCol.CHAPTER_INDEX));
    return chapter;
  }

  /** 全列映射，配合 ChapterCol.ALL 查询使用 */
  private static mapFullRow(rs: relationalStore.ResultSet): Chapter {
    const chapter = ChapterRepository.mapSummaryRow(rs);
    chapter.href = rs.getString(rs.getColumnIndex(ChapterCol.HREF));
    chapter.anchor = rs.getString(rs.getColumnIndex(ChapterCol.ANCHOR));

    const createdIdx: number = rs.getColumnIndex(ChapterCol.CREATED_AT);
    chapter.createdAt = rs.isColumnNull(createdIdx) ? 0 : rs.getLong(createdIdx);
    const updatedIdx: number = rs.getColumnIndex(ChapterCol.UPDATED_AT);
    chapter.updatedAt = rs.isColumnNull(updatedIdx) ? 0 : rs.getLong(updatedIdx);
    return chapter;
  }
}
