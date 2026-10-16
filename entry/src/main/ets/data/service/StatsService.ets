import { StatsSummary, DailyStats } from '../../model/DailyStats';
import { ReadingRecordSummary } from '../../model/ReadingRecord';
import { StatsRepository } from '../repository/StatsRepository';
import { DbConstants } from '../../common/constants/DbConstants';
import { DateUtil } from '../../common/utils/DateUtil';
import { LogTag } from '../../common/constants/AppConstants';
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
 * ⚠️ 原 `ShelfOverview` / `AnnotationCounts` / `bookDurationToday` /
 * `loadShelfOverview` / `loadAnnotationCounts` / `completionPercent` **已删除**：
 * 它们服务的「书架」「标注」区块已按用户要求从统计页移除（UI 不存在），
 * 方法零调用 —— 留着只会让人以为区块还在。将来做书籍详情页时按需重写，
 * 那时的取数口径（哪些数字、什么分组）应当由新页面的需求重新决定。
 */

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
   *
   * ⚠️ `bookTitle` 会作为**书名快照**存进统计行（见 `StatsCol.BOOK_TITLE`）：
   * 本表没有外键，书被物理删除后统计行会留下，不留快照的话
   * 阅读记录里那本书只能显示成「已移除的书」。
   * 调用方拿不到书名时可以传空串 —— 空串**不会覆盖**已存的快照。
   */
  static async submit(bookId: number, seconds: number, bookTitle: string = ''): Promise<void> {
    const whole: number = Math.floor(seconds);
    if (whole <= 0) {
      return;
    }
    try {
      await StatsRepository.addDuration(bookId, whole, bookTitle);
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

  /**
   * 「阅读记录」页要的全部数据：总时长 / 书数 / 天数 / 连续天数 / 每本书时长。
   *
   * ⚠️ **书数由列表长度得出**，不另查一次 `COUNT(DISTINCT book_id)` ——
   * 页面上"共 N 本"与下面的列表必须永远一致，两个数字来自两次查询就迟早
   * 会打架（统计表没有外键，删书后可能留下残行）。见 `ReadingRecordSummary`。
   *
   * ⚠️ 失败时**不吞异常**：本页的核心就是这些数字，
   * 返回一个全 0 的"成功"结果会让用户看到"总时长 0 分钟"并以为数据丢了。
   * 调用方（页面）负责把异常转成可重试的错误态 —— 与 `loadSummary` 同一取舍。
   */
  static async loadReadingRecord(): Promise<ReadingRecordSummary> {
    const result = new ReadingRecordSummary();
    result.totalSeconds = await StatsRepository.totalDuration();
    result.readingDays = await StatsRepository.readingDayCount();
    result.continuousDays = await StatsRepository.continuousDays();
    result.books = await StatsRepository.listBookDurations();
    result.bookCount = result.books.length;
    return result;
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
}
