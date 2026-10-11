import { Book } from '../../model/Book';
import { ReadingPosition } from '../../model/ReadingPosition';
import { BookRepository } from '../repository/BookRepository';
import { PageCache } from '../../model/PageCache';
import { PageCacheRepository } from '../repository/PageCacheRepository';
import { PaginationService } from './PaginationService';
import { AppConstants, LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';

/** 恢复出来的阅读位置，已换算成页码 */
export class RestoredPosition {
  /** 0-based 章节序号；-1 表示无进度，从第 0 章开始 */
  chapterIndex: number = -1;
  /** 章内 UTF-16 下标 */
  offset: number = 0;
  /** 在给定断点方案下的页码（0-based） */
  pageIndex: number = 0;
  /** 跨章节的全局百分比 0~1 */
  percent: number = 0;
  /** 是否命中了分页缓存 */
  cacheHit: boolean = false;
}

/**
 * 进度服务：节流落库 + 恢复定位 + 阅读时长累计。
 *
 * 两条铁律：
 *  1. 进度绝不存页码 —— 换字号页边界全变。只存"章节序号 + 章内偏移 + 百分比"；
 *  2. 不每页写库 —— 内存记进度，按 10 秒节流 / 切后台 / 退出阅读页时落库。
 */
export class ProgressService {
  private bookId: number = 0;
  private chapterIndex: number = -1;
  private offset: number = 0;
  private percent: number = 0;
  private readStatus: number = AppConstants.READ_STATUS_UNREAD;

  /** 是否有未落库的改动 */
  private dirty: boolean = false;
  private lastFlushAt: number = 0;

  /** 本次阅读会话开始时间戳；-1 表示未计时 */
  private sessionStartAt: number = -1;
  /** 最近一次用户操作时间；0 表示尚未有操作 */
  private lastActiveAt: number = 0;
  /** 已累计但未提交的阅读秒数 */
  private pendingSeconds: number = 0;

  constructor(bookId: number) {
    this.bookId = bookId;
    this.lastFlushAt = Date.now();
  }

  // ------------------------------------------------------------ 内存态更新

  /** 翻页 / 滚动时调用。只更新内存，不写库。 */
  updatePosition(chapterIndex: number, offset: number, percent: number): void {
    this.chapterIndex = chapterIndex;
    this.offset = offset;
    this.percent = ProgressService.clampPercent(percent);
    this.dirty = true;
    if (this.readStatus === AppConstants.READ_STATUS_UNREAD) {
      this.readStatus = AppConstants.READ_STATUS_READING;
    }
    this.markActive();
  }

  markFinished(): void {
    this.readStatus = AppConstants.READ_STATUS_FINISHED;
    this.dirty = true;
  }

  /** 记录一次用户操作，用于空闲判定与计时恢复 */
  markActive(): void {
    const now: number = Date.now();
    // 空闲超过阈值后重新操作：先结算空闲前的时间，再重新开始
    if (this.sessionStartAt >= 0 && this.lastActiveAt > 0
      && now - this.lastActiveAt > AppConstants.IDLE_TIMEOUT_MS) {
      this.accumulateSession(this.lastActiveAt);
      this.sessionStartAt = now;
    } else if (this.sessionStartAt < 0) {
      this.sessionStartAt = now;
    }
    this.lastActiveAt = now;
  }

  // ------------------------------------------------------------ 落库

  /**
   * 需要落库时调用（定时器 / 切后台 / 退出阅读页）。
   * 内部做节流：距上次落库不足 PROGRESS_FLUSH_INTERVAL_MS 且非强制时直接返回。
   *
   * @returns 本次累计的阅读秒数（未提交给统计则为 0）
   */
  async flush(force: boolean = false): Promise<number> {
    const now: number = Date.now();
    if (!force && !this.dirty
      && now - this.lastFlushAt < AppConstants.PROGRESS_FLUSH_INTERVAL_MS) {
      return 0;
    }

    const seconds: number = this.settleSeconds(now);

    if (this.dirty && this.chapterIndex >= 0) {
      const location: string = BookRepository.buildLocation(
        this.chapterIndex, this.offset, this.percent);
      try {
        await BookRepository.updateProgress(
          this.bookId, this.chapterIndex, this.offset, this.percent,
          location, this.readStatus);
        this.dirty = false;
        this.lastFlushAt = now;
      } catch (e) {
        Logger.error(LogTag.PROGRESS, `进度落库失败: ${Logger.errText(e as Object)}`);
      }
    }
    return seconds;
  }

  /** 立即结算并返回本次可提交的秒数 */
  private settleSeconds(now: number): number {
    if (this.sessionStartAt >= 0) {
      this.accumulateSession(now);
      this.sessionStartAt = now;
    }
    const seconds: number = this.pendingSeconds;
    this.pendingSeconds = 0;
    return seconds;
  }

  /** 把 [from, to] 区间计入 pendingSeconds，并对单次异常长的区间做截断 */
  private accumulateSession(to: number): void {
    const from: number = this.sessionStartAt;
    if (from < 0 || to <= from) {
      return;
    }
    // 防御脏数据：单次累计不超过 15 分钟（防进程被杀后 sessionStartAt 残留）
    const maxMs: number = 15 * 60 * 1000;
    const elapsedMs: number = Math.min(to - from, maxMs);
    this.pendingSeconds += Math.round(elapsedMs / 1000);
  }

  /** 退出阅读页：结算计时并强制落库 */
  async close(): Promise<number> {
    const seconds: number = await this.flush(true);
    this.sessionStartAt = -1;
    return seconds;
  }

  hasPendingChanges(): boolean {
    return this.dirty;
  }

  // ------------------------------------------------------------ 恢复

  /**
   * 恢复阅读位置。
   *
   * 定位靠 "offset → 断点数组"，与旧排版无关 ——
   * 所以 book 表**不需要**存"上次的排版指纹"。
   */
  static async restore(book: Book, layoutKey: string): Promise<RestoredPosition> {
    const restored = new RestoredPosition();
    restored.chapterIndex = book.lastChapterIndex;
    restored.offset = book.lastOffset;
    restored.percent = ProgressService.clampPercent(book.progressPercent);

    if (book.hasNoProgress()) {
      return restored;
    }

    const breaks: number[] = await PageCacheRepository.getBreaks(
      book.id, book.lastChapterIndex, layoutKey);
    if (breaks.length > 0) {
      restored.cacheHit = true;
      restored.pageIndex = PaginationService.locatePage(breaks, book.lastOffset);
    } else {
      // 未命中缓存：页码交给上层在算出分页后回填
      restored.cacheHit = false;
      restored.pageIndex = 0;
    }
    return restored;
  }

  /** 上层重算分页后回填页码 */
  static locate(breaks: number[], offset: number): number {
    return PageCache.locatePage(breaks, offset);
  }

  /** 由 location JSON 取位置（location 是 last_chapter_index / last_offset 的兼容层） */
  static fromLocation(book: Book): ReadingPosition {
    return book.currentPosition();
  }

  private static clampPercent(value: number): number {
    if (value < 0) {
      return 0;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }
}
