import { relationalStore } from '@kit.ArkData';
import { RdbHelper } from '../database/RdbHelper';
import { DailyStats, StatsSummary } from '../../model/DailyStats';
import { DbConstants, StatsCol } from '../../common/constants/DbConstants';
import { DateUtil } from '../../common/utils/DateUtil';
import { AppState } from '../../model/AppState';

const db = (): RdbHelper => RdbHelper.getInstance();

/**
 * 阅读统计仓储。
 *
 * 两个必须遵守的点：
 *  1. book_id = 0 是"全局统计"哨兵，不是脏数据，也不参与外键；
 *  2. 写入必须 upsert（ON CONFLICT ... DO UPDATE），否则同书同天会产生多条记录。
 *
 * 日期一律用本地时区的 YYYY-MM-DD；若用 UTC，晚上 8 点后的阅读会被算到"明天"，
 * 连续打卡天数会对不上。
 */
export class StatsRepository {
  /**
   * 累加阅读时长（秒）。同时更新"本书"与"全局(book_id=0)"两条记录。
   * seconds <= 0 时直接返回，避免无意义写入。
   */
  static async addDuration(bookId: number, seconds: number): Promise<void> {
    if (seconds <= 0) {
      return;
    }
    const date: string = DateUtil.today();
    const now: number = Date.now();
    await db().withTransaction<void>(async () => {
      await StatsRepository.upsert(bookId, date, seconds, now);
      if (bookId !== DbConstants.GLOBAL_STATS_BOOK_ID) {
        await StatsRepository.upsert(DbConstants.GLOBAL_STATS_BOOK_ID, date, seconds, now);
      }
    });
    AppState.bumpStats();
  }

  private static async upsert(
    bookId: number, date: string, seconds: number, now: number
  ): Promise<void> {
    const sql: string =
      `INSERT INTO ${DbConstants.TABLE_DAILY_STATS} (book_id, date, duration_seconds, updated_at) ` +
      `VALUES (?,?,?,?) ` +
      `ON CONFLICT(book_id, date) DO UPDATE SET ` +
      `duration_seconds = duration_seconds + excluded.duration_seconds, updated_at = excluded.updated_at`;
    await db().getStore().executeSql(sql, [bookId, date, seconds, now]);
  }

  // ------------------------------------------------------------ 汇总查询

  /** 全局某天时长（秒） */
  static async globalDuration(date: string): Promise<number> {
    return db().queryNumber(
      `SELECT IFNULL(SUM(duration_seconds), 0) FROM ${DbConstants.TABLE_DAILY_STATS} ` +
      `WHERE book_id = ? AND date = ?`,
      [DbConstants.GLOBAL_STATS_BOOK_ID, date], 0);
  }

  /** [from, to] 闭区间内的全局总时长（秒） */
  static async globalDurationRange(from: string, to: string): Promise<number> {
    return db().queryNumber(
      `SELECT IFNULL(SUM(duration_seconds), 0) FROM ${DbConstants.TABLE_DAILY_STATS} ` +
      `WHERE book_id = ? AND date >= ? AND date <= ?`,
      [DbConstants.GLOBAL_STATS_BOOK_ID, from, to], 0);
  }

  /** 全局总时长（秒） */
  static async totalDuration(): Promise<number> {
    return db().queryNumber(
      `SELECT IFNULL(SUM(duration_seconds), 0) FROM ${DbConstants.TABLE_DAILY_STATS} WHERE book_id = ?`,
      [DbConstants.GLOBAL_STATS_BOOK_ID], 0);
  }

  /** 某本书的总时长（秒） */
  static async bookTotalDuration(bookId: number): Promise<number> {
    return db().queryNumber(
      `SELECT IFNULL(SUM(duration_seconds), 0) FROM ${DbConstants.TABLE_DAILY_STATS} WHERE book_id = ?`,
      [bookId], 0);
  }

  /** 有阅读记录的日期数（阅读天数） */
  static async readingDayCount(): Promise<number> {
    return db().queryNumber(
      `SELECT COUNT(*) FROM ${DbConstants.TABLE_DAILY_STATS} WHERE book_id = ? AND duration_seconds > 0`,
      [DbConstants.GLOBAL_STATS_BOOK_ID], 0);
  }

  /**
   * 连续阅读天数：从今天（或昨天）往前回溯。
   *
   * 今天还没读不打断连续 —— 否则每天零点打开统计页会看到连续天数归零。
   */
  static async continuousDays(): Promise<number> {
    let cursor: string = DateUtil.today();
    if (await StatsRepository.globalDuration(cursor) <= 0) {
      cursor = DateUtil.shiftDateKey(cursor, -1);
      if (await StatsRepository.globalDuration(cursor) <= 0) {
        return 0;
      }
    }
    let days: number = 0;
    // 上限 10 年，防止异常数据导致死循环
    for (let i = 0; i < 3650; i++) {
      if (await StatsRepository.globalDuration(cursor) > 0) {
        days++;
        cursor = DateUtil.shiftDateKey(cursor, -1);
      } else {
        break;
      }
    }
    return days;
  }

  /** 某本书某天的时长（秒） */
  static async bookDurationOnDate(bookId: number, date: string): Promise<number> {
    return db().queryNumber(
      `SELECT IFNULL(SUM(duration_seconds), 0) FROM ${DbConstants.TABLE_DAILY_STATS} ` +
      `WHERE book_id = ? AND date = ?`,
      [bookId, date], 0);
  }

  /** 每日时长明细（统计页折线/柱状图用） */
  static async listDailyRange(bookId: number, from: string, to: string): Promise<DailyStats[]> {
    const list: DailyStats[] = [];
    await db().query(
      `SELECT ${StatsCol.ID}, ${StatsCol.BOOK_ID}, ${StatsCol.DATE}, ` +
      `${StatsCol.DURATION_SECONDS}, ${StatsCol.UPDATED_AT} ` +
      `FROM ${DbConstants.TABLE_DAILY_STATS} ` +
      `WHERE book_id = ? AND date >= ? AND date <= ? ORDER BY date ASC`,
      [bookId, from, to],
      (rs: relationalStore.ResultSet) => {
        const item = new DailyStats();
        item.id = rs.getLong(rs.getColumnIndex(StatsCol.ID));
        item.bookId = rs.getLong(rs.getColumnIndex(StatsCol.BOOK_ID));
        item.date = rs.getString(rs.getColumnIndex(StatsCol.DATE));
        item.durationSeconds = rs.getLong(rs.getColumnIndex(StatsCol.DURATION_SECONDS));

        const updatedIdx: number = rs.getColumnIndex(StatsCol.UPDATED_AT);
        item.updatedAt = rs.isColumnNull(updatedIdx) ? 0 : rs.getLong(updatedIdx);
        list.push(item);
      });
    return list;
  }

  /** 统计页一次取齐的汇总 */
  static async loadSummary(): Promise<StatsSummary> {
    const summary = new StatsSummary();
    const today: string = DateUtil.today();
    const weekStart: string = DateUtil.shiftDateKey(today, -6);

    summary.todaySeconds = await StatsRepository.globalDuration(today);
    summary.weekSeconds = await StatsRepository.globalDurationRange(weekStart, today);
    summary.totalSeconds = await StatsRepository.totalDuration();
    summary.readingDays = await StatsRepository.readingDayCount();
    summary.continuousDays = await StatsRepository.continuousDays();
    return summary;
  }
}
