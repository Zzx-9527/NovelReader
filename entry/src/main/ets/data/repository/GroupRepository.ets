import { relationalStore } from '@kit.ArkData';
import { RdbHelper } from '../database/RdbHelper';
import { BookGroup } from '../../model/BookGroup';
import { DbConstants, GroupCol } from '../../common/constants/DbConstants';
import { AppState } from '../../model/AppState';

const db = (): RdbHelper => RdbHelper.getInstance();

/**
 * 分组仓储。
 *
 * 关键点：删除分组必须在事务里手动把成员 group_id 置 NULL ——
 * 软删除不会触发外键的 ON DELETE SET NULL，
 * 不解绑的话这些书会因为指向已删分组而从书架消失。
 */
export class GroupRepository {
  static async listAll(): Promise<BookGroup[]> {
    const list: BookGroup[] = [];
    await db().query(
      `SELECT ${GroupCol.ALL} FROM ${DbConstants.TABLE_BOOK_GROUP} ` +
      `WHERE deleted = 0 ORDER BY sort_order ASC, id ASC`,
      [],
      (rs: relationalStore.ResultSet) => {
        list.push(GroupRepository.mapRow(rs));
      });
    return list;
  }

  /**
   * 全部分组，**附带组内书籍数量 + 可排序的时间字段**
   * （书架首页把分组当"书"显示，要标数量、还要参与同一套排序）。
   *
   * ⚠️ 用 `LEFT JOIN` + `COUNT(b.id)` 一次查完，不要"先查分组再逐个 COUNT"：
   * 后者是 N+1 次查询，而首页每次刷新都要跑。
   *
   * ⚠️ `COUNT(b.id)` 而不是 `COUNT(*)`：`LEFT JOIN` 下没有书的分组会产生
   * 一行 `b.*` 全 NULL 的记录，`COUNT(*)` 会把它算成 **1** ——
   * 空分组会显示"1 本"（这类"看起来对、其实差一"的错最难发现）。
   * `COUNT(列名)` 只数该列非 NULL 的行，正好跳过它。
   *
   * ⚠️ 书的过滤条件（`deleted = 0`）必须写在 **ON 子句**里，不能写在 WHERE：
   * 写在 WHERE 会把"没有书的空分组"整行滤掉 —— 空分组在首页就消失了，
   * 而用户刚建好的组必须可见（否则他以为没建成）。
   *
   * ⚠️ `MAX(b.last_read_at)` / `MAX(b.added_at)` 也走同一个 JOIN：
   * 分组要与书**混排**在同一套排序里（用户明确要求），就必须拿到
   * "组内最近阅读时间 / 最新导入时间"。再单独查一次是多余的 IO。
   * `MAX()` 对空分组返回 NULL，由下面的 mapRow 兜底
   * （`addedAt` 退回分组创建时间、`lastReadAt` 保持 null）。
   */
  static async listAllWithCount(): Promise<BookGroup[]> {
    await RdbHelper.ensureReady();
    const list: BookGroup[] = [];
    await db().query(
      `SELECT g.${GroupCol.ID} AS id, g.${GroupCol.NAME} AS name, ` +
      `g.${GroupCol.SORT_ORDER} AS sort_order, g.${GroupCol.CREATED_AT} AS created_at, ` +
      `g.${GroupCol.UPDATED_AT} AS updated_at, g.${GroupCol.DELETED} AS deleted, ` +
      `COUNT(b.id) AS book_count, ` +
      `MAX(b.last_read_at) AS last_read_at, MAX(b.added_at) AS max_added_at ` +
      `FROM ${DbConstants.TABLE_BOOK_GROUP} g ` +
      `LEFT JOIN ${DbConstants.TABLE_BOOK} b ` +
      `ON b.group_id = g.id AND b.deleted = 0 ` +
      `WHERE g.deleted = 0 ` +
      `GROUP BY g.id ` +
      `ORDER BY g.sort_order ASC, g.id ASC`,
      [],
      (rs: relationalStore.ResultSet) => {
        const group: BookGroup = GroupRepository.mapRow(rs);
        const countIdx: number = rs.getColumnIndex('book_count');
        group.bookCount = rs.isColumnNull(countIdx) ? 0 : rs.getLong(countIdx);

        /**
         * 组内最近阅读时间。**空分组（或组内都没读过）时是 NULL** ——
         * 保留为 `null` 而不是 0：排序时"从没读过"要排到最后，
         * 而 0 会被当成"很久以前读过"，语义不同（见 `ShelfEntry` 的排序）。
         */
        const readIdx: number = rs.getColumnIndex('last_read_at');
        group.lastReadAt = rs.isColumnNull(readIdx) ? null : rs.getLong(readIdx);

        /**
         * 组内最新导入时间；**空分组退回分组自身的创建时间**。
         *
         * ⚠️ 不能让空分组的时间为 0：在"导入时间"排序下它会掉到最后，
         * 而用户刚建好的组理应看得见（他甚至可能就是想先建组再加书）。
         */
        const addedIdx: number = rs.getColumnIndex('max_added_at');
        group.addedAt = rs.isColumnNull(addedIdx) ? group.createdAt : rs.getLong(addedIdx);

        list.push(group);
      });
    return list;
  }

  static async getById(groupId: number): Promise<BookGroup | null> {
    let group: BookGroup | null = null;
    await db().queryFirst(
      `SELECT ${GroupCol.ALL} FROM ${DbConstants.TABLE_BOOK_GROUP} WHERE id = ? AND deleted = 0`,
      [groupId],
      (rs: relationalStore.ResultSet) => {
        group = GroupRepository.mapRow(rs);
      });
    return group;
  }

  /**
   * 已删除的分组（供回收站清理）。
   *
   * ⚠️ **刻意保留但暂无调用者**（不要顺手删）：分组回收站 UI 未做；
   * "已删除的分组 + 组内书"的彻底清理目前靠 `wipeAll` 整库清空承担。
   */
  static async listDeleted(): Promise<BookGroup[]> {
    const list: BookGroup[] = [];
    await db().query(
      `SELECT ${GroupCol.ALL} FROM ${DbConstants.TABLE_BOOK_GROUP} WHERE deleted = 1`,
      [],
      (rs: relationalStore.ResultSet) => {
        list.push(GroupRepository.mapRow(rs));
      });
    return list;
  }

  /** 最大排序值，新建分组时排在最后 */
  static async maxSortOrder(): Promise<number> {
    return db().queryNumber(
      `SELECT IFNULL(MAX(sort_order), 0) FROM ${DbConstants.TABLE_BOOK_GROUP} WHERE deleted = 0`,
      [], 0);
  }

  /**
   * 新建分组。name 唯一（部分唯一索引保证未删除的分组不重名）。
   *
   * ⚠️ 用 typed `insert()` 直接拿 rowId，不要用 `executeSql` + 回查 ——
   * 事务内 `querySql` 读不到同一事务刚写入的行（见 BookRepository.insert 的说明）。
   */
  static async insert(name: string, sortOrder: number): Promise<number> {
    await RdbHelper.ensureReady();
    const now: number = Date.now();
    const bucket: relationalStore.ValuesBucket = {
      'name': name,
      'sort_order': sortOrder,
      'created_at': now,
      'updated_at': now,
      'deleted': 0
    };
    const newId: number = await db().getStore().insert(DbConstants.TABLE_BOOK_GROUP, bucket);
    if (newId > 0) {
      AppState.bumpGroup();
    }
    return newId;
  }

  static async rename(groupId: number, name: string): Promise<void> {
    await RdbHelper.ensureReady();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_BOOK_GROUP} SET name = ?, updated_at = ? WHERE id = ?`,
      [name, Date.now(), groupId]);
    AppState.bumpGroup();
  }

  /**
   * ⚠️ 原 `updateSortOrder` / `updateSortOrders` **已删除**（拖拽排序未做，
   * 两者零调用）。`sort_order` 目前只由新建时的 `maxSortOrder()+1` 决定，
   * 查询侧 `ORDER BY sort_order` 仍然正确。将来做分组拖拽排序时，
   * 用"事务内按列表下标批量落库"的写法重建批量版即可（单行版不需要）。
   */

  /** 某个分组下的书籍 id（含回收站中的书，确保全部解绑） */
  static async memberIds(groupId: number): Promise<number[]> {
    const ids: number[] = [];
    await db().query(
      `SELECT id FROM ${DbConstants.TABLE_BOOK} WHERE group_id = ?`,
      [groupId],
      (rs: relationalStore.ResultSet) => {
        ids.push(rs.getLong(0));
      });
    return ids;
  }

  /**
   * 删除分组：事务内先把成员全部置为"未分组"，再软删除分组本身。
   * @returns 被解绑的书籍数量
   */
  static async softDeleteWithMembers(groupId: number): Promise<number> {
    await RdbHelper.ensureReady();
    const store = db().getStore();
    const movedCount: number = await db().withTransaction<number>(async () => {
      const bookIds: number[] = await GroupRepository.memberIds(groupId);
      for (const bookId of bookIds) {
        await store.executeSql(
          `UPDATE ${DbConstants.TABLE_BOOK} SET group_id = NULL, updated_at = ? WHERE id = ?`,
          [Date.now(), bookId]);
      }
      await store.executeSql(
        `UPDATE ${DbConstants.TABLE_BOOK_GROUP} SET deleted = 1, updated_at = ? WHERE id = ?`,
        [Date.now(), groupId]);
      return bookIds.length;
    });
    AppState.bumpGroup();
    AppState.bumpBookshelf();
    return movedCount;
  }

  /** 与已有分组重名时会触发唯一索引冲突，先查一下便于给出友好提示 */
  static async existsByName(name: string, excludeId: number): Promise<boolean> {
    const count: number = await db().queryNumber(
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_BOOK_GROUP} WHERE name = ? AND deleted = 0 AND id <> ?`,
      [name, excludeId], 0);
    return count > 0;
  }

  private static mapRow(rs: relationalStore.ResultSet): BookGroup {
    const group = new BookGroup();
    group.id = rs.getLong(rs.getColumnIndex(GroupCol.ID));
    group.name = rs.getString(rs.getColumnIndex(GroupCol.NAME));
    group.sortOrder = rs.getLong(rs.getColumnIndex(GroupCol.SORT_ORDER));
    group.deleted = rs.getLong(rs.getColumnIndex(GroupCol.DELETED));

    const createdIdx: number = rs.getColumnIndex(GroupCol.CREATED_AT);
    group.createdAt = rs.isColumnNull(createdIdx) ? 0 : rs.getLong(createdIdx);
    const updatedIdx: number = rs.getColumnIndex(GroupCol.UPDATED_AT);
    group.updatedAt = rs.isColumnNull(updatedIdx) ? 0 : rs.getLong(updatedIdx);
    return group;
  }
}
