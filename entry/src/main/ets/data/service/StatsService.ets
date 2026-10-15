import { StatsSummary, DailyStats } from '../../model/DailyStats';
import { StatsRepository } from '../repository/StatsRepository';
import { DbConstants } from '../../common/constants/DbConstants';
import { DateUtil } from '../../common/utils/DateUtil';
import { AppConstants, LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';

/** 柱状图的一天（接口形式，跨 ForEach 使用必须用 interface） */
export interface DayBar {
  /** MM-DD */
  label: string;
  /** 当天秒数 */
  seconds: number;
  /** 是否今天 */
  isToday: boolean;
}

/**
 * 阅读统计服务。
 *
 * 与 ProgressService 的分工：
 *  - ProgressService 管"读到哪了"，并按会话累计出可提交的秒数；
 *  - StatsService 负责把秒数写进 reading_daily_stats（本书 + 全局两条）。
 */
export class StatsService {
  /**
   * 提交一段阅读时长。
   * seconds 会被向下取整；不足 1 秒不写入，避免大量无意义行。
   */
  static async submit(bookId: number, seconds: number): Promise<void> {
    const whole: number = Math.floor(seconds);
    if (whole <= 0) {
      return;
    }
    try {
      await StatsRepository.addDuration(bookId, whole);
    } catch (e) {
      Logger.error(LogTag.STATS, `阅读时长落库失败: ${Logger.errText(e as Object)}`);
    }
  }

  /** 统计页要的全部汇总 */
  static async loadSummary(): Promise<StatsSummary> {
    return StatsRepository.loadSummary();
  }

  /** 某本书的累计阅读时长（秒） */
  static async bookDuration(bookId: number): Promise<number> {
    return StatsRepository.bookTotalDuration(bookId);
  }

  /** 某本书在指定日期的阅读时长（秒），用于书籍详情页"今天读了多久" */
  static async bookDurationToday(bookId: number): Promise<number> {
    return StatsRepository.bookDurationOnDate(bookId, todayKey());
  }

  /** 最近 N 天的每日全局时长（统计页柱状图用），补齐无记录的日期 */
  static async loadRecentBars(fromKey: string, toKey: string): Promise<DayBar[]> {
    const rows: DailyStats[] =
      await StatsRepository.listDailyRange(DbConstants.GLOBAL_STATS_BOOK_ID, fromKey, toKey);
    const byDate: Map<string, number> = new Map();
    for (const r of rows) {
      byDate.set(r.date, r.durationSeconds);
    }
    const bars: DayBar[] = [];
    let cursor: string = fromKey;
    const today: string = DateUtil.today();
    while (cursor <= toKey) {
      const item: DayBar = {
        label: cursor.substring(5),
        seconds: byDate.get(cursor) ?? 0,
        isToday: cursor === today
      };
      bars.push(item);
      cursor = DateUtil.shiftDateKey(cursor, 1);
    }
    return bars;
  }

  /** 书籍完成度：优先用阅读百分比，读完状态直接算 100% */
  static completionPercent(progressPercent: number, readStatus: number): number {
    if (readStatus === AppConstants.READ_STATUS_FINISHED) {
      return 100;
    }
    const clamped: number = progressPercent < 0 ? 0 : (progressPercent > 1 ? 1 : progressPercent);
    return Math.round(clamped * 100);
  }
}

/** 本地时区的今天（避免各调用点各写一套） */
function todayKey(): string {
  const d = new Date();
  const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
