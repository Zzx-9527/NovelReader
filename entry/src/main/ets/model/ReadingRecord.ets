/**
 * 阅读记录（「我的 → 阅读记录」页用）。
 *
 * ⚠️ 数据全部来自 `reading_daily_stats` 这一张表，**没有新建表**：
 * 它的每一行本来就是"某本书在某一天读了多少秒"（`UNIQUE(book_id, date)`），
 * 按 `book_id` 分组求和就是每本书的累计时长，按 `book_id = 0` 求和就是全局时长。
 * 再加一张"每本书总计"的汇总表，等于把同一份事实存两遍、多一个会不同步的地方。
 */

/**
 * 单本书的累计阅读时长。
 *
 * ⚠️ 必须是 `interface` 而不是 `class`：它要经 `ForEach` 渲染。
 * 本项目对此有实测教训（见 `StatsService.DayBar` 的同一条注释）——
 * 跨 `ForEach` 传递的数据用 interface，避免 class 实例在复用组件时
 * 出现"字段不触发更新"的问题。
 */
export interface BookReadingRecord {
  /** 书籍 id（`ForEach` 的键来源） */
  bookId: number;
  /** 书名；空串由页面回退成「未命名」 */
  title: string;
  /** 累计阅读时长（秒），恒 > 0 */
  seconds: number;
}

/**
 * 阅读记录页一次取齐的汇总。
 *
 * ⚠️ `bookCount` 由 `books.length` 得出，**不单独查一次 `COUNT(DISTINCT book_id)`**：
 * 那样两个数字的来源不同，一旦统计表里有已删书籍的残留行，
 * 就会出现"写着 7 本、列表只有 6 行"的矛盾。
 * 判据：**页面上互相印证的两个数字，必须来自同一次查询。**
 */
export class ReadingRecordSummary {
  /** 全局累计阅读时长（秒），来自 book_id = 0 的哨兵行 */
  totalSeconds: number = 0;
  /** 有阅读时长的书的数量（= books.length） */
  bookCount: number = 0;
  /** 有阅读记录的天数 */
  readingDays: number = 0;
  /** 连续阅读天数 */
  continuousDays: number = 0;
  /** 按累计时长降序的书单 */
  books: BookReadingRecord[] = [];
}
