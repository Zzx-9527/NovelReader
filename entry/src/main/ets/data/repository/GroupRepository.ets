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

  /** 已删除的分组（供回收站清理） */
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

  static async updateSortOrder(groupId: number, sortOrder: number): Promise<void> {
    await RdbHelper.ensureReady();
    await db().getStore().executeSql(
      `UPDATE ${DbConstants.TABLE_BOOK_GROUP} SET sort_order = ?, updated_at = ? WHERE id = ?`,
      [sortOrder, Date.now(), groupId]);
    AppState.bumpGroup();
  }

  /** 批量更新排序（拖拽排序后一次落库） */
  static async updateSortOrders(groups: BookGroup[]): Promise<void> {
    await RdbHelper.ensureReady();
    const store = db().getStore();
    await db().withTransaction<void>(async () => {
      for (let i = 0; i < groups.length; i++) {
        await store.executeSql(
          `UPDATE ${DbConstants.TABLE_BOOK_GROUP} SET sort_order = ?, updated_at = ? WHERE id = ?`,
          [i, Date.now(), groups[i].id]);
      }
    });
    AppState.bumpGroup();
    AppState.bumpBookshelf();
  }

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
