import { StatsSummary, DailyStats } from '../../model/DailyStats';
import { ReadingRecordSummary } from '../../model/ReadingRecord';
import { Book } from '../../model/Book';
import { BookRepository, BookSort } from '../repository/BookRepository';
import { AnnotationRepository } from '../repository/AnnotationRepository';
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

/** 书架总览（统计页"书架"区块用） */
export class ShelfOverview {
  /** 书架上的书总数 */
  bookCount: number = 0;
  /** 全部书的字数合计 */
  totalChars: number = 0;
  /** 读了一部分还没读完的书数 */
  readingCount: number = 0;
  /** 已读完的书数 */
  finishedCount: number = 0;
}

/** 标注计数（统计页"标注"区块用） */
export class AnnotationCounts {
  bookmarkCount: number = 0;
  highlightCount: number = 0;
  noteCount: number = 0;
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

  /**
   * 书架总览：书数 / 总字数 / 收尾中的书数（读了一部分还没读完的）。
   *
   * ⚠️ 数据从 BookRepository 现查而不是另建汇总表：书架是几本到几十本的量级，
   * `listShelf` 一次查询足够快，为三个数字建缓存表是过度设计。
   */
  static async loadShelfOverview(): Promise<ShelfOverview> {
    const overview = new ShelfOverview();
    try {
      const books: Book[] = await BookRepository.listShelf(BookSort.LAST_READ, null);
      overview.bookCount = books.length;
      let totalChars: number = 0;
      let reading: number = 0;
      let finished: number = 0;
      for (const b of books) {
        totalChars += b.wordCount;
        if (b.readStatus === AppConstants.READ_STATUS_FINISHED) {
          finished += 1;
        } else if (b.progressPercent > 0 && b.progressPercent < 1) {
          reading += 1;
        }
      }
      overview.totalChars = totalChars;
      overview.readingCount = reading;
      overview.finishedCount = finished;
    } catch (e) {
      Logger.error(LogTag.STATS, `书架总览加载失败: ${Logger.errText(e as Object)}`);
    }
    return overview;
  }

  /**
   * 标注统计：书签 / 划线 / 笔记 各多少条。
   *
   * ⚠️ `AnnotationRepository` 只有 `countByBook`（按书计数），
   * 全库计数在这里用 `countByBook` 遍历 —— 书架量级小（几十本），
   * 每本一条 COUNT(*) 查询的总开销可接受；不为三个数字加 SQL。
   */
  static async loadAnnotationCounts(): Promise<AnnotationCounts> {
    const counts = new AnnotationCounts();
    try {
      const books: Book[] = await BookRepository.listShelf(BookSort.LAST_READ, null);
      for (const b of books) {
        counts.bookmarkCount += await AnnotationRepository.countByBook(b.id, AppConstants.ANNOTATION_BOOKMARK);
        counts.highlightCount += await AnnotationRepository.countByBook(b.id, AppConstants.ANNOTATION_HIGHLIGHT);
        counts.noteCount += await AnnotationRepository.countByBook(b.id, AppConstants.ANNOTATION_NOTE);
      }
    } catch (e) {
      Logger.error(LogTag.STATS, `标注统计加载失败: ${Logger.errText(e as Object)}`);
    }
    return counts;
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
