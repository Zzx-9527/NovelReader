import { relationalStore } from '@kit.ArkData';
import { RdbHelper } from '../database/RdbHelper';
import { Book } from '../../model/Book';
import { ReadingPosition } from '../../model/ReadingPosition';
import { BookCol, DbConstants, StatsCol } from '../../common/constants/DbConstants';
import { AppConstants } from '../../common/constants/AppConstants';
import { AppState } from '../../model/AppState';

/** 判重结果类型 */
export enum HashLookup {
  /** 没有这本书 */
  NONE = 0,
  /** 命中一本在架的书 */
  ACTIVE = 1,
  /** 命中一本已软删除的书（应询问用户：恢复还是作为新书导入） */
  DELETED = 2
}

export class HashLookupResult {
  status: HashLookup = HashLookup.NONE;
  book: Book | null = null;
}

/** 书架排序方式 */
export enum BookSort {
  LAST_READ = 'last_read',
  ADDED = 'added',
  TITLE = 'title'
}

const db = (): RdbHelper => RdbHelper.getInstance();

/**
 * 书籍仓储：唯一允许写 book 表 SQL 的地方。
 *
 * 约定：
 *  - 所有对外的查询都带 `deleted = 0`（除显式查回收站），统一在这里拼；
 *  - 返回 model 对象，绝不把 ResultSet 泄漏给上层；
 *  - 写操作成功后自增 AppStorage 的版本号，书架页据此刷新。
 */
export class BookRepository {
  // ------------------------------------------------------------ 查询

  static async getById(id: number): Promise<Book | null> {
    await RdbHelper.ensureReady();
    let book: Book | null = null;
    await db().queryFirst(
      `SELECT ${BookCol.ALL} FROM ${DbConstants.TABLE_BOOK} WHERE id = ? AND deleted = 0`,
      [id],
      (rs: relationalStore.ResultSet) => {
        book = BookRepository.mapRow(rs);
      });
    return book;
  }

  /** 按 uuid 查（重新导入时对账用） */
  static async getByUuid(uuid: string): Promise<Book | null> {
    await RdbHelper.ensureReady();
    let book: Book | null = null;
    await db().queryFirst(
      `SELECT ${BookCol.ALL} FROM ${DbConstants.TABLE_BOOK} WHERE uuid = ?`,
      [uuid],
      (rs: relationalStore.ResultSet) => {
        book = BookRepository.mapRow(rs);
      });
    return book;
  }

  /**
   * 按内容指纹判重。
   * 返回的 book 在 ACTIVE / DELETED 两种情况下都不为空。
   */
  static async findByHash(fileHash: string): Promise<HashLookupResult> {
    await RdbHelper.ensureReady();
    const result = new HashLookupResult();
    if (fileHash.length === 0) {
      return result;
    }
    await db().query(
      `SELECT ${BookCol.ALL} FROM ${DbConstants.TABLE_BOOK} ` +
      `WHERE file_hash = ? ORDER BY deleted ASC, id ASC`,
      [fileHash],
      (rs: relationalStore.ResultSet) => {
        const book: Book = BookRepository.mapRow(rs);
        if (book.deleted === 0) {
          if (result.status !== HashLookup.ACTIVE) {
            result.status = HashLookup.ACTIVE;
            result.book = book;
          }
        } else if (result.book === null) {
          result.status = HashLookup.DELETED;
          result.book = book;
        }
      });
    return result;
  }

  /** 书架列表（不含回收站） */
  static async listShelf(sort: BookSort, groupId: number | null): Promise<Book[]> {
    await RdbHelper.ensureReady();
    let sql: string = `SELECT ${BookCol.ALL} FROM ${DbConstants.TABLE_BOOK} WHERE deleted = 0`;
    const args: Array<relationalStore.ValueType> = [];
    if (groupId !== null) {
      sql += ` AND group_id = ?`;
      args.push(groupId);
    }
    if (sort === BookSort.LAST_READ) {
      // 从未读过的排在最后，而不是被当成 0 排到最前
      sql += ` ORDER BY last_read_at IS NULL, last_read_at DESC, id DESC`;
    } else if (sort === BookSort.ADDED) {
      sql += ` ORDER BY added_at DESC`;
    } else {
      sql += ` ORDER BY title ASC`;
    }
    const list: Book[] = [];
    await db().query(sql, args, (rs: relationalStore.ResultSet) => {
      list.push(BookRepository.mapRow(rs));
    });
    return list;
  }

  /**
   * **未分组**的书籍（书架首页在"分组当文件夹"模式下显示这些）。
   *
   * ⚠️ 与 `listShelf(sort, null)` 的区别：后者是"不限分组"（返回**全部**书），
   * 本方法才是"没有归入任何分组"（`group_id IS NULL`）。
   * 两者只差一个 SQL 条件，但语义完全相反 —— 首页要的是后者：
   * 已归组的书只应出现在它所属的分组里，不该在首页再出现一次。
   */
  static async listUngrouped(sort: BookSort): Promise<Book[]> {
    await RdbHelper.ensureReady();
    let sql: string =
      `SELECT ${BookCol.ALL} FROM ${DbConstants.TABLE_BOOK} ` +
      `WHERE deleted = 0 AND group_id IS NULL`;
    if (sort === BookSort.LAST_READ) {
      // 从未读过的排在最后，而不是被当成 0 排到最前
      sql += ` ORDER BY last_read_at IS NULL, last_read_at DESC, id DESC`;
    } else if (sort === BookSort.ADDED) {
      sql += ` ORDER BY added_at DESC`;
    } else {
      sql += ` ORDER BY title ASC`;
    }
    const list: Book[] = [];
    await db().query(sql, [], (rs: relationalStore.ResultSet) => {
      list.push(BookRepository.mapRow(rs));
    });
    return list;
  }

  /**
   * **已分组**的全部书籍，按"分组 → 排序"输出。
   *
   * 用途：分组封面要拿"组内前几本书"（`BookGroup.coverBooks`）。
   *
   * ⚠️ 一次查完、在内存里按组切前 N 本，**不要**"每个分组查一次"：
   * 后者是 N+1 次 IO，而首页每次刷新都要跑。
   * 一本书只属于一个分组（`book.groupId` 是单值），所以这里的数据量
   * 就是"全部已归组的书"，对本地小说库（几十到几百本）完全可控。
   *
   * ⚠️ `ORDER BY group_id` 必须在**排序键之前**：先按组聚拢，
   * 组内再按用户选的排序，这样"每组前 4 本"才是该组里最该显示的那 4 本。
   * 反过来（先按 last_read 再按 group）会让同一组的书散落在结果各处。
   */
  static async listGrouped(sort: BookSort): Promise<Book[]> {
    await RdbHelper.ensureReady();
    let sql: string =
      `SELECT ${BookCol.ALL} FROM ${DbConstants.TABLE_BOOK} ` +
      `WHERE deleted = 0 AND group_id IS NOT NULL ` +
      `ORDER BY group_id ASC, `;
    if (sort === BookSort.LAST_READ) {
      sql += `last_read_at IS NULL, last_read_at DESC, id DESC`;
    } else if (sort === BookSort.ADDED) {
      sql += `added_at DESC`;
    } else {
      sql += `title ASC`;
    }
    const list: Book[] = [];
    await db().query(sql, [], (rs: relationalStore.ResultSet) => {
      list.push(BookRepository.mapRow(rs));
    });
    return list;
  }

  /** 继续阅读卡片：最近读过且未读完的一本 */
  static async getContinueReading(): Promise<Book | null> {
    await RdbHelper.ensureReady();
    let book: Book | null = null;
    await db().queryFirst(
      `SELECT ${BookCol.ALL} FROM ${DbConstants.TABLE_BOOK} ` +
      `WHERE deleted = 0 AND last_read_at IS NOT NULL AND read_status <> ? ` +
      `ORDER BY last_read_at DESC LIMIT 1`,
      [AppConstants.READ_STATUS_FINISHED],
      (rs: relationalStore.ResultSet) => {
        book = BookRepository.mapRow(rs);
      });
    return book;
  }

  /**
   * ⚠️ 以下方法**刻意保留但暂无调用者**（不要顺手删）：
   *  - `listDeleted` / `restore`：回收站的读/恢复两端，回收站 UI 未做；
   *  - `countUngrouped` / `countAll`：书架统计备用（存储占用行将来可扩展）；
   *  - `searchByTitle`：书架搜索改走了内存过滤（`applySearch`，见
   *    `BookShelfViewModel`），本 SQL 版是为"书量上千后内存过滤变慢"
   *    预留的升级路径 —— 现在删掉，到时要重写。
   */

  /** 回收站列表 */
  static async listDeleted(): Promise<Book[]> {
    await RdbHelper.ensureReady();
    const list: Book[] = [];
    await db().query(
      `SELECT ${BookCol.ALL} FROM ${DbConstants.TABLE_BOOK} WHERE deleted = 1 ORDER BY updated_at DESC`,
      [],
      (rs: relationalStore.ResultSet) => {
        list.push(BookRepository.mapRow(rs));
      });
    return list;
  }

  static async countInGroup(groupId: number): Promise<number> {
    await RdbHelper.ensureReady();
    return db().queryNumber(
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_BOOK} WHERE deleted = 0 AND group_id = ?`,
      [groupId], 0);
  }

  /** 未分组书籍数 */
  static async countUngrouped(): Promise<number> {
    await RdbHelper.ensureReady();
    return db().queryNumber(
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_BOOK} WHERE deleted = 0 AND group_id IS NULL`,
      [], 0);
  }

  static async countAll(): Promise<number> {
    await RdbHelper.ensureReady();
    return db().queryNumber(
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_BOOK} WHERE deleted = 0`, [], 0);
  }

  /** 书名模糊匹配（书架内搜索，不是全文搜索） */
  static async searchByTitle(keyword: string): Promise<Book[]> {
    await RdbHelper.ensureReady();
    const list: Book[] = [];
    await db().query(
      `SELECT ${BookCol.ALL} FROM ${DbConstants.TABLE_BOOK} ` +
      `WHERE deleted = 0 AND (title LIKE ? OR author LIKE ?) ORDER BY last_read_at IS NULL, last_read_at DESC`,
      [`%${keyword}%`, `%${keyword}%`],
      (rs: relationalStore.ResultSet) => {
        list.push(BookRepository.mapRow(rs));
      });
    return list;
  }

  // ------------------------------------------------------------ 写入

  /**
   * 插入书籍，返回自增主键。
   *
   * ⚠️ 必须用 typed `store.insert()`，不能写成 `executeSql` + 回查主键。
   * 实测结论（自检页 A/B/C/D 四组对照）：
   *   - 事务外，`executeSql` 插入后回查能拿到 id（A 组正常）；
   *   - **事务内，`querySql` 读不到同一事务刚写入的数据**：B 组回查得 0、
   *     D 组连 `last_insert_rowid()` 都得 0，但提交后该行确实存在；
   *   - typed `insert()` 直接返回 rowId、不查库，因此不受此限制（C 组正常）。
   *
   * 导入整条链都在事务里，所以这里必须是能直接拿 rowId 的写法。
   */
  static async insert(book: Book): Promise<number> {
    await RdbHelper.ensureReady();
    const now: number = Date.now();
    if (book.addedAt <= 0) {
      book.addedAt = now;
    }
    if (book.updatedAt <= 0) {
      book.updatedAt = now;
    }
    const bucket: relationalStore.ValuesBucket = BookRepository.toBucket(book);
    const newId: number = await db().getStore().insert(DbConstants.TABLE_BOOK, bucket);
    if (newId > 0) {
      book.id = newId;
      AppState.bumpBookshelf();
    }
    return newId;
  }

  /** Book -> ValuesBucket（列名与 DbSchema 严格一致） */
  private static toBucket(book: Book): relationalStore.ValuesBucket {
    const bucket: relationalStore.ValuesBucket = {
      'uuid': book.uuid,
      'title': book.title,
      'author': book.author,
      'cover_path': book.coverPath,
      'file_path': book.filePath,
      'format': book.format,
      'encoding': book.encoding,
      'file_size': book.fileSize,
      'file_hash': book.fileHash,
      'group_id': book.groupId,
      'total_chapters': book.totalChapters,
      'word_count': book.wordCount,
      'added_at': book.addedAt,
      'updated_at': book.updatedAt,
      'last_read_at': book.lastReadAt,
      'last_chapter_index': book.lastChapterIndex,
      'last_offset': book.lastOffset,
      'read_status': book.readStatus,
      'progress_percent': book.progressPercent,
      'location': book.location,
      'parse_status': book.parseStatus,
      'parse_error': book.parseError,
      'parse_rule': book.parseRule,
      'metadata': book.metadata,
      'deleted': book.deleted
    };
    return bucket;
  }

  /** 全量更新（不改 uuid / added_at） */
  static async update(book: Book): Promise<void> {
    await RdbHelper.ensureReady();
    book.updatedAt = Date.now();
    const sql: string =
      `UPDATE ${DbConstants.TABLE_BOOK} SET title = ?, author = ?, cover_path = ?, file_path = ?, ` +
      `format = ?, encoding = ?, file_size = ?, file_hash = ?, group_id = ?, total_chapters = ?, ` +
      `word_count = ?, updated_at = ?, last_read_at = ?, last_chapter_index = ?, last_offset = ?, ` +
      `read_status = ?, progress_percent = ?, location = ?, parse_status = ?, parse_error = ?, ` +
      `parse_rule = ?, metadata = ?, deleted = ? WHERE id = ?`;
    await db().getStore().executeSql(sql, [
      book.title, book.author, book.coverPath, book.filePath, book.format, book.encoding,
      book.fileSize, book.fileHash, book.groupId, book.totalChapters, book.wordCount,
      book.updatedAt, book.lastReadAt, book.lastChapterIndex, book.lastOffset,
      book.readStatus, book.progressPercent, book.location, book.parseStatus,
      book.parseError, book.parseRule, book.metadata, book.deleted, book.id
    ]);
    AppState.bumpBookshelf();
  }

  /** 只更新解析相关字段，避免整行覆写把并发改动冲掉 */
  static async updateParseState(
    bookId: number, status: number, error: string, rule: string,
    totalChapters: number, wordCount: number
  ): Promise<void> {
    await RdbHelper.ensureReady();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_BOOK} SET parse_status = ?, parse_error = ?, parse_rule = ?, ` +
      `total_chapters = ?, word_count = ?, updated_at = ? WHERE id = ?`,
      [status, error, rule, totalChapters, wordCount, Date.now(), bookId]);
    AppState.bumpBookshelf();
  }

  /**
   * 落库阅读进度。
   * location 与 last_chapter_index / last_offset 必须同源同事务写入。
   */
  static async updateProgress(
    bookId: number, chapterIndex: number, offset: number,
    percent: number, location: string, readStatus: number
  ): Promise<void> {
    await RdbHelper.ensureReady();
    const now: number = Date.now();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_BOOK} SET last_chapter_index = ?, last_offset = ?, ` +
      `progress_percent = ?, location = ?, read_status = ?, last_read_at = ?, updated_at = ? WHERE id = ?`,
      [chapterIndex, offset, percent, location, readStatus, now, now, bookId]);
    AppState.bumpBookshelf();
    AppState.setCurrentBook(bookId);
  }

  /** 只更新最后阅读时间（打开书但没翻页时用） */
  static async touchLastRead(bookId: number): Promise<void> {
    await RdbHelper.ensureReady();
    const now: number = Date.now();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_BOOK} SET last_read_at = ? WHERE id = ?`, [now, bookId]);
    AppState.bumpBookshelf();
  }

  /**
   * 移入/移出分组。
   * @param groupId 传 null 表示"未分组"；类型用 ValueType 以匹配 SQL 绑定参数
   */
  static async setGroup(bookId: number, groupId: relationalStore.ValueType): Promise<void> {
    await RdbHelper.ensureReady();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_BOOK} SET group_id = ?, updated_at = ? WHERE id = ?`,
      [groupId, Date.now(), bookId]);
    AppState.bumpBookshelf();
  }

  static async rename(bookId: number, title: string, author: string): Promise<void> {
    await RdbHelper.ensureReady();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_BOOK} SET title = ?, author = ?, updated_at = ? WHERE id = ?`,
      [title, author, Date.now(), bookId]);
    AppState.bumpBookshelf();
  }

  /** 软删除：标记 deleted = 1，沙箱文件保留以便恢复 */
  static async softDelete(bookId: number): Promise<void> {
    await RdbHelper.ensureReady();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_BOOK} SET deleted = 1, updated_at = ? WHERE id = ?`,
      [Date.now(), bookId]);
    AppState.bumpBookshelf();
  }

  static async restore(bookId: number): Promise<void> {
    await RdbHelper.ensureReady();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_BOOK} SET deleted = 0, updated_at = ? WHERE id = ?`,
      [Date.now(), bookId]);
    AppState.bumpBookshelf();
  }

  /**
   * 物理删除；chapter / page_cache / annotation 由外键 CASCADE 带走（需外键已开启）。
   *
   * ⚠️⚠️ **删除前必须先把书名回填进统计行**，否则阅读记录里那本书
   * 只能显示「已移除的书」—— 本表（`reading_daily_stats`）**没有外键**，
   * 统计行不会被 CASCADE 带走，而书名只存在于即将被删掉的 `book` 行里。
   *
   * 这一步是"快照"机制的另一半：
   *  - 写入时快照（`StatsService.submit` 带 `bookTitle`）覆盖"读过之后被删"；
   *  - 删除时回填覆盖"**从未读过、或读过但快照为空**就被删"的情况 ——
   *    例如"移除到回收站 → 重新导入同一文件"，那条路径会直接 hardDelete
   *    旧记录（见 `ImportService`），旧记录的统计行可能是补列之前写的、
   *    快照为空。只靠写入时快照会漏掉这一批。
   *
   * ⚠️ 顺序不能反：先回填、后删除。反了就没有书名可回填了。
   * ⚠️ 回填只写 `book_title = ''` 的行，不覆盖已有快照 ——
   * 已有快照可能来自改名前的写入，但"删除时的书名"才是最终名，
   * 这里选择**不覆盖**是为了与 `StatsRepository.upsert` 的
   * `CASE WHEN excluded.book_title <> ''` 保持同一套语义（非空即权威）。
   */
  static async hardDelete(bookId: number): Promise<void> {
    await RdbHelper.ensureReady();
    /**
     * ⚠️ 用 `IFNULL(子查询, book_title)` 而不是裸子查询：
     * 子查询在"书已经不存在"时返回 **NULL**，而 `book_title` 是
     * `NOT NULL` 列 —— 直接赋值会抛约束错误，把一次正常的删除变成失败。
     * 包一层 `IFNULL` 后，取不到书名就**保持原值**（等于没改），
     * 删除照常完成。幂等调用（对同一个 id 删两次）因此也是安全的。
     */
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_DAILY_STATS} SET ${StatsCol.BOOK_TITLE} = IFNULL(` +
      `(SELECT ${BookCol.TITLE} FROM ${DbConstants.TABLE_BOOK} WHERE ${BookCol.ID} = ?), ` +
      `${StatsCol.BOOK_TITLE}) ` +
      `WHERE ${StatsCol.BOOK_ID} = ? AND ${StatsCol.BOOK_TITLE} = ''`,
      [bookId, bookId]);
    await db().getStore().executeSql(
      `DELETE FROM ${DbConstants.TABLE_BOOK} WHERE id = ?`, [bookId]);
    AppState.bumpBookshelf();
    // 统计行可能刚被回填，让统计页/阅读记录重查一次
    AppState.bumpStats();
  }

  /** 标记文件丢失 */
  static async markFileMissing(bookId: number, parseRule: string): Promise<void> {
    await RdbHelper.ensureReady();
    await BookRepository.updateParseState(
      bookId, AppConstants.PARSE_FAILED, '文件丢失', parseRule, 0, 0);
  }

  /**
   * 清空全部数据（"数据管理"里的"清空所有数据"）。
   *
   * ⚠️ 单事务清空 6 张表（不 DROP，保留表结构与索引）：
   *  - book / chapter / annotation / book_group / reading_daily_stats / page_cache；
   *  - 沙箱里的书源文件**不删**（用户可能还要文件），只清库；
   *  - 清空后 bump 书架与统计两个版本号，让在库的页面各自刷新。
   *
   * 顺序无所谓（没有外键引用问题），但必须在同一事务里 ——
   * 中途失败宁可什么都不清，也不要留下半清状态。
   */
  static async wipeAll(): Promise<void> {
    await RdbHelper.ensureReady();
    const tables: string[] = [
      DbConstants.TABLE_ANNOTATION,
      DbConstants.TABLE_PAGE_CACHE,
      DbConstants.TABLE_CHAPTER,
      DbConstants.TABLE_BOOK,
      DbConstants.TABLE_BOOK_GROUP,
      DbConstants.TABLE_DAILY_STATS
    ];
    await db().withTransaction<void>(async () => {
      for (const t of tables) {
        await db().getStore().executeSql(`DELETE FROM ${t}`);
      }
    });
    AppState.bumpBookshelf();
    AppState.bumpGroup();
    AppState.bumpStats();
  }

  // ------------------------------------------------------------ 映射

  private static mapRow(rs: relationalStore.ResultSet): Book {
    const book = new Book();
    book.id = rs.getLong(rs.getColumnIndex(BookCol.ID));
    book.uuid = rs.getString(rs.getColumnIndex(BookCol.UUID));
    book.title = rs.getString(rs.getColumnIndex(BookCol.TITLE));
    book.author = rs.getString(rs.getColumnIndex(BookCol.AUTHOR));
    book.coverPath = rs.getString(rs.getColumnIndex(BookCol.COVER_PATH));
    book.filePath = rs.getString(rs.getColumnIndex(BookCol.FILE_PATH));
    book.format = rs.getString(rs.getColumnIndex(BookCol.FORMAT));
    book.encoding = rs.getString(rs.getColumnIndex(BookCol.ENCODING));
    book.fileSize = rs.getLong(rs.getColumnIndex(BookCol.FILE_SIZE));
    book.fileHash = rs.getString(rs.getColumnIndex(BookCol.FILE_HASH));

    const groupIdx: number = rs.getColumnIndex(BookCol.GROUP_ID);
    book.groupId = rs.isColumnNull(groupIdx) ? null : rs.getLong(groupIdx);

    book.totalChapters = rs.getLong(rs.getColumnIndex(BookCol.TOTAL_CHAPTERS));
    book.wordCount = rs.getLong(rs.getColumnIndex(BookCol.WORD_COUNT));
    book.addedAt = rs.getLong(rs.getColumnIndex(BookCol.ADDED_AT));
    book.updatedAt = rs.getLong(rs.getColumnIndex(BookCol.UPDATED_AT));

    const lastReadIdx: number = rs.getColumnIndex(BookCol.LAST_READ_AT);
    book.lastReadAt = rs.isColumnNull(lastReadIdx) ? null : rs.getLong(lastReadIdx);

    book.lastChapterIndex = rs.getLong(rs.getColumnIndex(BookCol.LAST_CHAPTER_INDEX));
    book.lastOffset = rs.getLong(rs.getColumnIndex(BookCol.LAST_OFFSET));
    book.readStatus = rs.getLong(rs.getColumnIndex(BookCol.READ_STATUS));
    book.progressPercent = rs.getDouble(rs.getColumnIndex(BookCol.PROGRESS_PERCENT));
    book.location = rs.getString(rs.getColumnIndex(BookCol.LOCATION));
    book.parseStatus = rs.getLong(rs.getColumnIndex(BookCol.PARSE_STATUS));
    book.parseError = rs.getString(rs.getColumnIndex(BookCol.PARSE_ERROR));
    book.parseRule = rs.getString(rs.getColumnIndex(BookCol.PARSE_RULE));
    book.metadata = rs.getString(rs.getColumnIndex(BookCol.METADATA));
    book.deleted = rs.getLong(rs.getColumnIndex(BookCol.DELETED));
    return book;
  }

  /** 便于上层构造 location JSON */
  static buildLocation(chapterIndex: number, offset: number, percent: number): string {
    const pos = new ReadingPosition();
    pos.type = AppConstants.FORMAT_TXT;
    pos.chapterIndex = chapterIndex;
    pos.offset = offset;
    pos.percent = percent;
    return pos.toJson();
  }
}
