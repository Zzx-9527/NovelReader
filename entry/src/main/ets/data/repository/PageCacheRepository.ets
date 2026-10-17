import { relationalStore } from '@kit.ArkData';
import { RdbHelper } from '../database/RdbHelper';
import { PageCache } from '../../model/PageCache';
import { DbConstants, PageCacheCol } from '../../common/constants/DbConstants';

const db = (): RdbHelper => RdbHelper.getInstance();

/**
 * 分页缓存仓储。
 *
 * page_cache 是【纯派生数据】：可以直接清空，不需要软删除列。
 * layout_key 由 PaginationService 根据排版参数生成；
 * 换字号 / 旋转屏幕只会写入新的 key，旧 key 的行由"清除缓存"回收。
 */
export class PageCacheRepository {
  /** 取某个排版方案下的断点数组；没有缓存返回空数组 */
  static async getBreaks(
    bookId: number, chapterIndex: number, layoutKey: string
  ): Promise<number[]> {
    const raw: string = await db().queryString(
      `SELECT ${PageCacheCol.BREAKS} FROM ${DbConstants.TABLE_PAGE_CACHE} ` +
      `WHERE book_id = ? AND chapter_index = ? AND layout_key = ?`,
      [bookId, chapterIndex, layoutKey], '');
    const breaks: number[] = PageCache.breaksFromJson(raw);
    // 缓存损坏（长度不足或首元素不为 0）按未命中处理，让上层重算
    if (breaks.length === 0 || breaks[0] !== 0) {
      return [];
    }
    return breaks;
  }

  /** 整条读取（含 pageCount / updatedAt），用于诊断与统计缓存命中率 */
  static async get(
    bookId: number, chapterIndex: number, layoutKey: string
  ): Promise<PageCache | null> {
    let cache: PageCache | null = null;
    await db().queryFirst(
      `SELECT ${PageCacheCol.ID}, ${PageCacheCol.BOOK_ID}, ${PageCacheCol.CHAPTER_INDEX}, ` +
      `${PageCacheCol.LAYOUT_KEY}, ${PageCacheCol.BREAKS}, ${PageCacheCol.PAGE_COUNT}, ` +
      `${PageCacheCol.UPDATED_AT} FROM ${DbConstants.TABLE_PAGE_CACHE} ` +
      `WHERE book_id = ? AND chapter_index = ? AND layout_key = ?`,
      [bookId, chapterIndex, layoutKey],
      (rs: relationalStore.ResultSet) => {
        const item = new PageCache();
        item.id = rs.getLong(rs.getColumnIndex(PageCacheCol.ID));
        item.bookId = rs.getLong(rs.getColumnIndex(PageCacheCol.BOOK_ID));
        item.chapterIndex = rs.getLong(rs.getColumnIndex(PageCacheCol.CHAPTER_INDEX));
        item.layoutKey = rs.getString(rs.getColumnIndex(PageCacheCol.LAYOUT_KEY));
        item.breaks = PageCache.breaksFromJson(rs.getString(rs.getColumnIndex(PageCacheCol.BREAKS)));
        item.pageCount = rs.getLong(rs.getColumnIndex(PageCacheCol.PAGE_COUNT));

        const updatedIdx: number = rs.getColumnIndex(PageCacheCol.UPDATED_AT);
        item.updatedAt = rs.isColumnNull(updatedIdx) ? 0 : rs.getLong(updatedIdx);
        cache = item;
      });
    return cache;
  }

  /** 写入或覆盖某个排版方案下的断点 */
  static async save(
    bookId: number, chapterIndex: number, layoutKey: string, breaks: number[]
  ): Promise<void> {
    await RdbHelper.ensureReady();
    if (breaks.length === 0) {
      return;
    }
    await db().getStore().executeSql(
      `INSERT OR REPLACE INTO ${DbConstants.TABLE_PAGE_CACHE} (` +
      `book_id, chapter_index, layout_key, breaks, page_count, updated_at` +
      `) VALUES (?,?,?,?,?,?)`,
      [bookId, chapterIndex, layoutKey, PageCache.breaksToJson(breaks), breaks.length, Date.now()]);
  }

  /** 清理某本书的全部缓存（删除书籍或重新分章时调用） */
  static async deleteByBook(bookId: number): Promise<void> {
    await db().getStore().executeSql(
      `DELETE FROM ${DbConstants.TABLE_PAGE_CACHE} WHERE book_id = ?`, [bookId]);
  }

  /** 清理已不存在的书残留的缓存（兜底：万一外键 CASCADE 没生效） */
  static async deleteOrphans(): Promise<void> {
    await db().getStore().executeSql(
      `DELETE FROM ${DbConstants.TABLE_PAGE_CACHE} ` +
      `WHERE book_id NOT IN (SELECT id FROM ${DbConstants.TABLE_BOOK})`);
  }

  /** 清理已软删除书籍的缓存，回收空间（配合回收站清理） */
  static async deleteForDeletedBooks(): Promise<void> {
    await db().getStore().executeSql(
      `DELETE FROM ${DbConstants.TABLE_PAGE_CACHE} ` +
      `WHERE book_id IN (SELECT id FROM ${DbConstants.TABLE_BOOK} WHERE deleted = 1)`);
  }

  static async countAll(): Promise<number> {
    return db().queryNumber(
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_PAGE_CACHE}`, [], 0);
  }

  /**
   * 缓存的近似磁盘占用（字节）。
   *
   * ⚠️ 用 `SUM(LENGTH(...))` 估算而不是去量数据库文件：
   * SQLite 文件还有页结构/空闲页，精确拆出单表占用做不到；
   * 这里把每行的 breaks JSON、layout_key 与固定列开销加起来，
   * 结果略小于真实占用 —— 对"这缓存值不值得清"的判断足够准。
   */
  static async usageBytes(): Promise<number> {
    return db().queryNumber(
      `SELECT IFNULL(SUM(LENGTH(${PageCacheCol.BREAKS}) + LENGTH(${PageCacheCol.LAYOUT_KEY}) + 48), 0) ` +
      `FROM ${DbConstants.TABLE_PAGE_CACHE}`, [], 0);
  }

  /** 某本书的缓存条目数 */
  static async countByBook(bookId: number): Promise<number> {
    return db().queryNumber(
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_PAGE_CACHE} WHERE book_id = ?`, [bookId], 0);
  }

  /** 清空全部缓存（设置页"清除缓存"） */
  static async clearAll(): Promise<void> {
    await db().clearPageCache();
  }
}
