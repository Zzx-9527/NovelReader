import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { CREATE_INDEX_SQL, CREATE_TABLE_SQL } from '../../common/constants/DbSchema';
import { DbConstants, StatsCol } from '../../common/constants/DbConstants';
import { AppConstants, LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';

const ERR_NOT_INIT: string = 'RdbHelper 尚未初始化，请先调用 RdbHelper.init(context)';

/**
 * 数据库单例：建表、索引、事务、版本迁移。
 *
 * 关于建表：HarmonyOS RDB 没有 onCreate 回调，所以用
 * `getRdbStore` + `CREATE ... IF NOT EXISTS` 幂等建表，
 * 再配合 `store.version` 决定是否需要执行迁移。
 *
 * 注意：`store.version` 默认值就是 0，因此不能用 0 表示"全新数据库"；
 * 真正的判据是"表还不存在"。靠 IF NOT EXISTS 天然幂等，不依赖标志位。
 *
 * 只允许 data/repository/ 下的类使用本类，ViewModel 与 View 一律不碰。
 */
export class RdbHelper {
  private static instance: RdbHelper | null = null;
  /** 由 EntryAbility 在启动时注入，供 ensureReady 自愈初始化使用 */
  private static appContext: common.Context | null = null;
  /** 正在进行/已完成的初始化，保证并发调用只执行一次 */
  private static readyPromise: Promise<void> | null = null;

  private store: relationalStore.RdbStore | null = null;
  private initializing: Promise<void> | null = null;

  static getInstance(): RdbHelper {
    if (RdbHelper.instance === null) {
      RdbHelper.instance = new RdbHelper();
    }
    return RdbHelper.instance;
  }

  static async init(context: common.Context): Promise<void> {
    RdbHelper.appContext = context;
    await RdbHelper.ensureReady();
  }

  /**
   * 幂等就绪确认。任何数据访问前都应 await 它。
   *
   * 这样即使 UI 抢在 EntryAbility 初始化完成前发起查询，也不会抛"尚未初始化" ——
   * 初始化顺序不再是需要靠调用方小心翼翼维护的隐式契约。
   */
  static async ensureReady(): Promise<void> {
    if (RdbHelper.readyPromise === null) {
      if (RdbHelper.appContext === null) {
        throw new Error('RdbHelper 尚未注入 Context：EntryAbility.onCreate 里必须调用 RdbHelper.init(context)');
      }
      RdbHelper.readyPromise = RdbHelper.getInstance().initialize(RdbHelper.appContext);
    }
    await RdbHelper.readyPromise;
  }

  isReady(): boolean {
    return this.store !== null;
  }

  getStore(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error(ERR_NOT_INIT);
    }
    return this.store;
  }

  /** 幂等初始化：并发调用只会真正执行一次 */
  async initialize(context: common.Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.initializing !== null) {
      await this.initializing;
      return;
    }
    this.initializing = this.doInitialize(context);
    try {
      await this.initializing;
    } finally {
      this.initializing = null;
    }
  }

  private async doInitialize(context: common.Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DbConstants.DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    this.store = store;

    // 外键默认关闭，必须显式打开
    await this.execIgnoreError('PRAGMA foreign_keys = ON');

    const oldVersion: number = store.version;
    await this.applySchema();
    await this.migrate(oldVersion);

    if (store.version !== DbConstants.DB_VERSION) {
      store.version = DbConstants.DB_VERSION;
    }
    Logger.info(LogTag.DB,
      `数据库就绪: ${DbConstants.DB_NAME}, v${oldVersion} -> v${store.version}`);
  }

  /**
   * 建表 + 建索引。全部语句都是 IF NOT EXISTS，可反复执行。
   * 表顺序严格按 CREATE_TABLE_SQL 的数组顺序（外键依赖）。
   */
  private async applySchema(): Promise<void> {
    const store = this.getStore();
    for (const sql of CREATE_TABLE_SQL) {
      await store.executeSql(sql);
    }
    for (const sql of CREATE_INDEX_SQL) {
      await store.executeSql(sql);
    }
  }

  /**
   * 版本迁移。
   *
   * 注意：**开发期改 DDL 只需把 DbConstants.SCHEMA_BUILD +1**，
   * 库文件名会跟着变，等于每次都用全新的库，不会出现"旧表结构污染新代码"。
   * 本节负责的是**发布后**的平滑升级：在同一个库文件内按版本号补列/补表。
   *
   * 约束：
   *  - 每新增一步都必须幂等（IF NOT EXISTS 或先查 PRAGMA table_info）——
   *    用户可能在迁移中途被杀进程，下次启动会重跑；
   *  - 只允许加列 / 加表 / 加索引。SQLite 不支持修改列类型或删除列，
   *    真要改就得走"建新表→拷数据→换名"，那属于发布级的破坏性变更，需要单独评估。
   *
   * ⚠️⚠️ **本方法在 `doInitialize()` 内部执行，绝对不能调用任何会
   * `await RdbHelper.ensureReady()` 的方法**（`query` / `queryFirst` /
   * `queryNumber` / `queryDouble` / `queryString` / `withTransaction`）。
   *
   * 原因：`ensureReady()` 等的就是 `doInitialize()` 自己那个 promise，
   * 从初始化内部再等它 = **等自己**，永远不 resolve。表现为整个 app 起不来
   * （书架永远停在骨架屏、没有报错、日志也停在"数据库就绪"之前）——
   * 本项目实测踩过：`hasColumn()` 曾用 `query()`，加了迁移步骤后直接自锁。
   *
   * 需要查询时用 `queryOnStore()`（它没有那道闸门）。
   * 判据：**初始化路径上的查询必须绕过就绪闸门。**
   */
  private async migrate(oldVersion: number): Promise<void> {
    if (oldVersion > DbConstants.DB_VERSION) {
      // 用户装了旧版应用打开新版数据库：只告警，不回滚，避免丢数据
      Logger.warn(LogTag.DB,
        `数据库版本(${oldVersion})高于当前应用(${DbConstants.DB_VERSION})，已跳过迁移`);
      return;
    }
    if (oldVersion === DbConstants.DB_VERSION) {
      return;
    }
    /**
     * V2：`reading_daily_stats` 补 `book_title` 列（书名快照）。
     *
     * ⚠️ 为什么需要它：该表**没有外键**，书被物理删除后统计行会留下，
     * 而书名只在 `book` 表 —— 阅读记录里那本书因此只能显示「已移除的书」。
     * 补这一列之后，删书前写入过的书名会保留下来。
     *
     * ⚠️ 历史行无法回溯补名（书可能已经删了，无处可查）：它们保持空串，
     * 读取时回退成「已移除的书」。这是可接受的 —— 新写入的行从此正常。
     */
    if (oldVersion < 2) {
      await this.addColumnIfMissing(
        DbConstants.TABLE_DAILY_STATS, StatsCol.BOOK_TITLE, `TEXT NOT NULL DEFAULT ''`);
    }
    Logger.info(LogTag.DB,
      `执行迁移: v${oldVersion} -> v${DbConstants.DB_VERSION}（已补 book_title）`);
  }

  /**
   * 幂等加列：列已存在则跳过。
   * 供后续版本迁移使用，避免 ALTER TABLE 重复执行报错。
   */
  async addColumnIfMissing(table: string, column: string, definition: string): Promise<void> {
    if (await this.hasColumn(table, column)) {
      return;
    }
    await this.getStore().executeSql(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
    Logger.info(LogTag.DB, `已补列: ${table}.${column}`);
  }

  /**
   * 某张表是否存在指定列。
   *
   * ⚠️ **必须走 `queryOnStore()`，不能用 `query()`** ——
   * `query()` 开头会 `await ensureReady()`，而本方法唯一的调用者是
   * `migrate()`，它在 `doInitialize()` **内部**执行：
   * `ensureReady()` 等的正是 `doInitialize()` 自己那个 promise，
   * 于是"初始化等查询、查询等初始化"，**永久卡死**。
   * 症状是整个 app 起不来（书架一直停在骨架屏）—— 本项目实测踩过。
   * 判据：**初始化路径上的任何查询都必须绕过就绪闸门。**
   */
  async hasColumn(table: string, column: string): Promise<boolean> {
    let found: boolean = false;
    await this.queryOnStore(`PRAGMA table_info(${table})`, [],
      (rs: relationalStore.ResultSet) => {
        if (rs.getString(1) === column) {
          found = true;
        }
      });
    return found;
  }

  /**
   * 初始化期间专用查询：**不走 `ensureReady()`**。
   *
   * ⚠️ 与 `query()` 的唯一区别就是**没有那道就绪闸门**，存在的理由见
   * `hasColumn` 的说明（从初始化内部 await 闸门会自锁）。
   * 调用前提：`doInitialize()` 已经把 `this.store` 赋值完毕 ——
   * `applySchema()` / `migrate()` 都在那之后执行，因此这里 `getStore()`
   * 一定拿得到。
   *
   * ⚠️ 初始化之外的代码**不要**用它：那时该走 `query()`，
   * 才能保证"UI 抢在初始化完成前查询"不会读到半建好的库。
   */
  private async queryOnStore(
    sql: string,
    args: Array<relationalStore.ValueType>,
    onRow: (rs: relationalStore.ResultSet) => void
  ): Promise<void> {
    const rs = await this.getStore().querySql(sql, args);
    try {
      while (rs.goToNextRow()) {
        onRow(rs);
      }
    } finally {
      rs.close();
    }
  }

  private async execIgnoreError(sql: string): Promise<void> {
    try {
      await this.getStore().executeSql(sql);
    } catch (e) {
      Logger.warn(LogTag.DB, `执行 SQL 失败(已忽略): ${Logger.errText(e as Object)}`);
    }
  }

  /**
   * 事务包装。异常时回滚并把原始错误抛给调用方。
   * 所有多表写入（导入入库、进度落库、删除分组）都必须走这里。
   *
   * 事务开始时重设 PRAGMA foreign_keys：RDB 是连接池，同一开关在
   * 不同连接上可能是关闭的；而整库初始化时设置的 PRAGMA 只作用于当时那条连接。
   * 不这么做的话，ON DELETE CASCADE 可能悄悄失效，删书会留下孤儿章节。
   */
  async withTransaction<T>(action: () => Promise<T>): Promise<T> {
    await RdbHelper.ensureReady();
    const store = this.getStore();
    await this.execIgnoreError('PRAGMA foreign_keys = ON');
    store.beginTransaction();
    try {
      const result: T = await action();
      store.commit();
      return result;
    } catch (e) {
      try {
        store.rollBack();
      } catch (rollbackErr) {
        Logger.error(LogTag.DB, `回滚失败: ${Logger.errText(rollbackErr as Object)}`);
      }
      throw e as Error;
    }
  }

  /**
   * 确定性验证外键是否真的生效。
   *
   * 做法：在一个注定回滚的事务里插入一条 book_id 指向不存在书籍的 chapter。
   *  - 外键开启 → 抛约束错误 → 返回 true
   *  - 外键关闭 → 插入成功 → 返回 false（随后回滚，不留数据）
   *
   * 不能用 `PRAGMA foreign_keys` 的查询结果直接判断：连接池里换一条连接读，
   * 拿到的可能不是同一个值。
   */
  async verifyForeignKeyEnforced(): Promise<boolean> {
    const store = this.getStore();
    await this.execIgnoreError('PRAGMA foreign_keys = ON');
    store.beginTransaction();
    let enforced: boolean = false;
    try {
      await store.executeSql(
        `INSERT INTO ${DbConstants.TABLE_CHAPTER} (book_id, title, chapter_index) VALUES (?,?,?)`,
        [-999999, 'fk-probe', -999999]);
      // 没抛错说明外键没生效
      enforced = false;
    } catch (e) {
      enforced = true;
    } finally {
      try {
        store.rollBack();
      } catch (rollbackErr) {
        Logger.warn(LogTag.DB, '外键探测回滚失败（可忽略）');
      }
    }
    return enforced;
  }

  /** 诊断用：列出库中全部索引名 */
  async listIndexNames(): Promise<string[]> {
    const names: string[] = [];
    await this.query(`SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name`,
      [], (rs: relationalStore.ResultSet) => {
        names.push(rs.getString(0));
      });
    return names;
  }

  /**
   * 通用查询：自动关闭 ResultSet，调用方只管逐行读取。
   *
   * 这样仓储层不必重复写 try/finally；忘记 close 是 RDB 最常见的资源泄漏来源。
   */
  async query(
    sql: string,
    args: Array<relationalStore.ValueType>,
    onRow: (rs: relationalStore.ResultSet) => void
  ): Promise<void> {
    await RdbHelper.ensureReady();
    const rs = await this.getStore().querySql(sql, args);
    try {
      while (rs.goToNextRow()) {
        onRow(rs);
      }
    } finally {
      rs.close();
    }
  }

  /** 查询第一行并交给回调；无结果返回 false */
  async queryFirst(
    sql: string,
    args: Array<relationalStore.ValueType>,
    onRow: (rs: relationalStore.ResultSet) => void
  ): Promise<boolean> {
    await RdbHelper.ensureReady();
    const rs = await this.getStore().querySql(sql, args);
    try {
      if (rs.goToNextRow()) {
        onRow(rs);
        return true;
      }
      return false;
    } finally {
      rs.close();
    }
  }

  /** 查询单个整数（COUNT / MAX / SUM）。无结果返回 fallback。 */
  async queryNumber(
    sql: string, args: Array<relationalStore.ValueType>, fallback: number
  ): Promise<number> {
    await RdbHelper.ensureReady();
    const rs = await this.getStore().querySql(sql, args);
    try {
      if (rs.goToNextRow()) {
        return rs.getLong(0);
      }
      return fallback;
    } finally {
      rs.close();
    }
  }

  /** 查询单个浮点。无结果返回 fallback。 */
  async queryDouble(
    sql: string, args: Array<relationalStore.ValueType>, fallback: number
  ): Promise<number> {
    const rs = await this.getStore().querySql(sql, args);
    try {
      if (rs.goToNextRow()) {
        return rs.getDouble(0);
      }
      return fallback;
    } finally {
      rs.close();
    }
  }

  /** 查询单个字符串。无结果或为 NULL 时返回 fallback。 */
  async queryString(
    sql: string, args: Array<relationalStore.ValueType>, fallback: string
  ): Promise<string> {
    const rs = await this.getStore().querySql(sql, args);
    try {
      if (rs.goToNextRow() && !rs.isColumnNull(0)) {
        return rs.getString(0);
      }
      return fallback;
    } finally {
      rs.close();
    }
  }

  /** 清空全部分页缓存（设置页"清除缓存"用） */
  async clearPageCache(): Promise<void> {
    await this.getStore().executeSql(`DELETE FROM ${DbConstants.TABLE_PAGE_CACHE}`);
  }

  /** 便于诊断：某张表是否存在 */
  async hasTable(tableName: string): Promise<boolean> {
    const count: number = await this.queryNumber(
      `SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, [tableName], 0);
    return count > 0;
  }

  /** 诊断用：确认解析状态常量与库内取值一致 */
  static describeSchemaVersion(): string {
    return `v${DbConstants.DB_VERSION}（解析状态 ${AppConstants.PARSE_PENDING}/${AppConstants.PARSE_RUNNING}/`
      + `${AppConstants.PARSE_SUCCESS}/${AppConstants.PARSE_FAILED}）`;
  }
}
