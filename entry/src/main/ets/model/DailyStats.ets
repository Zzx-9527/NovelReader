import { DbConstants } from '../common/constants/DbConstants';

/**
 * 每日阅读统计（纯数据）。
 * bookId = DbConstants.GLOBAL_STATS_BOOK_ID(0) 表示全局统计。
 * date 为本地时区的 YYYY-MM-DD。
 */
export class DailyStats {
  id: number = 0;
  bookId: number = DbConstants.GLOBAL_STATS_BOOK_ID;
  date: string = '';
  durationSeconds: number = 0;
  updatedAt: number = 0;
}

/** 统计页要展示的一组汇总数据 */
export class StatsSummary {
  todaySeconds: number = 0;
  weekSeconds: number = 0;
  totalSeconds: number = 0;
  /** 有阅读记录的天数 */
  readingDays: number = 0;
  /** 连续阅读天数 */
  continuousDays: number = 0;
}
