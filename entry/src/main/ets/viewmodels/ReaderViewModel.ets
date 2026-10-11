import { BusinessError } from '@kit.BasicServicesKit';
import { Book } from '../model/Book';
import { Chapter } from '../model/Chapter';
import { ReadingPosition } from '../model/ReadingPosition';
import { ReaderSettings } from '../model/ReaderSettings';
import { PageCache } from '../model/PageCache';
import { ReaderState } from './ReaderState';
import { AppState } from '../model/AppState';
import { BookRepository } from '../data/repository/BookRepository';
import { ChapterRepository } from '../data/repository/ChapterRepository';
import { PageCacheRepository } from '../data/repository/PageCacheRepository';
import { SettingsService } from '../data/service/SettingsService';
import { ChapterReadService } from '../data/service/ChapterReadService';
import { PaginationService } from '../data/service/PaginationService';
import { ProgressService, RestoredPosition } from '../data/service/ProgressService';
import { StatsService } from '../data/service/StatsService';
import { RawFileSource } from '../data/source/RawFileSource';
import { PathUtil } from '../common/utils/PathUtil';
import { ReaderTheme } from '../common/theme/AppTheme';
import { AppConstants, LogTag } from '../common/constants/AppConstants';
import { Logger } from '../common/utils/Logger';

/** 滚动上报节流（毫秒），避免滚动时疯狂更新状态 */
const SCROLL_REPORT_INTERVAL_MS: number = 200;

/**
 * 阅读页 ViewModel。
 *
 * 关键约定（见设计文档 5.1 铁律）：
 *  - 进度只存"章节序号 + 章内偏移 + 百分比"，**绝不存页码**；
 *  - 分页断点按 `layoutKey` 缓存，换字号/旋转屏幕会换 key、自动重算；
 *  - 进度节流落库，不每页写库。
 */
export class ReaderViewModel {
  state: ReaderState = new ReaderState();
  private bookId: number = 0;
  private readService: ChapterReadService | null = null;
  private progress: ProgressService | null = null;
  private layoutKey: string = '';
  private contentWidth: number = 0;
  private contentHeight: number = 0;
  private lastScrollReportAt: number = 0;
  /**
   * 待恢复的章内偏移。
   *
   * 为什么需要它：分页依赖正文区实际尺寸，而尺寸要等首帧布局后才知道。
   * 于是流程是 open()（恢复进度）→ 拿到尺寸 → 重算分页 → 重新 loadChapter()，
   * 而 loadChapter 会把 offset 归零 —— 不加这个字段，恢复的进度就被清掉了。
   * 取值 -1 表示"无需恢复，从章首开始"。
   */
  private restoreToOffset: number = -1;

  get readerTheme(): ReaderTheme {
    return ReaderTheme.of(this.state.settings.theme);
  }

  // ------------------------------------------------------------ 打开

  async open(bookId: number): Promise<void> {
    this.bookId = bookId;
    this.state.loading = true;
    try {
      const book: Book | null = await BookRepository.getById(bookId);
      if (book === null) {
        this.state.error = '书籍不存在或已被删除';
        return;
      }
      if (!PathUtil.exists(book.filePath)) {
        this.state.error = '文件丢失，请在书籍详情页重新导入';
        await BookRepository.markFileMissing(bookId, book.parseRule);
        return;
      }

      this.state.book = book;
      this.state.settings = SettingsService.getInstance().loadReaderSettings();
      this.state.chapters = await ChapterRepository.listByBook(bookId);
      if (this.state.chapters.length === 0) {
        this.state.error = '这本书还没有章节，请尝试重新分章';
        return;
      }

      const source = RawFileSource.tryOpen(PathUtil.toAbsolute(book.filePath));
      if (source === null) {
        this.state.error = '无法打开文件';
        return;
      }
      this.readService = new ChapterReadService(source, book.encoding, book.id);
      this.progress = new ProgressService(bookId);
      this.progress.markActive();

      await this.restorePosition(book);
      AppState.setCurrentBook(bookId);
      await BookRepository.touchLastRead(bookId);
      this.state.error = '';
    } catch (e) {
      this.state.error = `打开失败：${Logger.errText(e as BusinessError)}`;
    } finally {
      this.state.loading = false;
    }
  }

  /** 按进度恢复：定位章节 → 取分页断点 → 算出页码 */
  private async restorePosition(book: Book): Promise<void> {
    const pos: ReadingPosition = book.currentPosition();
    const chapterIndex: number = pos.chapterIndex < 0 ? 0 : pos.chapterIndex;
    // 记下要恢复到的位置：拿到正文区尺寸后还会重新分页并重载本章，
    // 届时 loadChapter 会归零 offset，需要靠这个字段把位置找回来。
    this.restoreToOffset = book.hasNoProgress() ? 0 : pos.offset;
    await this.loadChapter(chapterIndex);
    this.state.percent = pos.percent;
    if (chapterIndex > 0 || book.hasNoProgress()) {
      // 章节位置已恢复；章内偏移为 0 或由后续重新分页时统一处理
      this.renderAt(0);
      this.state.percent = pos.percent;
      return;
    }
    this.renderAt(pos.offset);
  }

  /** 进入阅读页时由页面提供正文区尺寸 */
  setContentSize(width: number, height: number): void {
    this.contentWidth = width;
    this.contentHeight = height;
  }

  // ------------------------------------------------------------ 章节加载

  async loadChapter(chapterIndex: number): Promise<void> {
    if (this.readService === null || chapterIndex < 0 || chapterIndex >= this.state.chapters.length) {
      return;
    }
    this.state.loading = true;
    try {
      const chapter: Chapter = this.state.chapters[chapterIndex];
      const text: string = this.readService.decodeChapter(
        chapter.startOffset, chapter.endOffset, null);
      if (text.length === 0) {
        this.state.error = `第 ${chapter.displayNumber()} 章内容为空，可能文件已变化`;
        return;
      }
      // 取出并消费"待恢复偏移"：分页重建后要回到这里，而不是章首
      const target: number = this.restoreToOffset;
      this.restoreToOffset = -1;

      this.state.chapterIndex = chapterIndex;
      this.state.chapterTitle = chapter.title;
      this.state.setFullText(text);
      this.state.pageIndex = 0;
      this.state.offset = 0;
      this.state.error = '';
      await this.buildPagination();
      // target >= 0 时说明是"恢复进度"触发的加载，定位到该偏移；否则停在章首
      this.renderAt(target >= 0 ? target : 0);
      this.progress?.updatePosition(chapterIndex, this.state.offset, this.computePercent());
    } catch (e) {
      this.state.error = `加载章节失败：${Logger.errText(e as BusinessError)}`;
    } finally {
      this.state.loading = false;
    }
  }

  /** 取分页断点：先查缓存，未命中则计算并写回 */
  private async buildPagination(): Promise<void> {
    if (this.state.settings.pageMode === 'scroll'
      || this.contentWidth <= 0 || this.contentHeight <= 0) {
      this.state.breaks = [];
      this.state.pageCount = 1;
      return;
    }
    const book: Book | null = this.state.book;
    if (book === null) {
      return;
    }
    this.layoutKey = PaginationService.buildLayoutKey(
      this.state.settings, this.contentWidth, this.contentHeight);

    const cached: number[] = await PageCacheRepository.getBreaks(
      book.id, this.state.chapterIndex, this.layoutKey);
    if (cached.length > 0) {
      this.state.breaks = cached;
      this.state.pageCount = cached.length;
      return;
    }

    this.state.repaginating = true;
    try {
      const breaks: number[] = PaginationService.computeBreaks(
        this.state.getFullText(), this.state.settings, this.contentWidth, this.contentHeight);
      this.state.breaks = breaks;
      this.state.pageCount = breaks.length;
      await PageCacheRepository.save(book.id, this.state.chapterIndex, this.layoutKey, breaks);
    } finally {
      this.state.repaginating = false;
    }
  }

  // ------------------------------------------------------------ 渲染与定位

  /** 按偏移定位：算出页码并切出该页文本 */
  renderAt(offset: number): void {
    const text: string = this.state.getFullText();
    const clamped: number = Math.max(0, Math.min(offset, Math.max(0, text.length - 1)));

    if (this.state.settings.pageMode === 'scroll' || this.state.breaks.length === 0) {
      this.state.offset = clamped;
      this.state.pageIndex = 0;
      this.state.pageCount = 1;
      this.state.renderedText = text;
      return;
    }

    const pageIndex: number = PaginationService.locatePage(this.state.breaks, clamped);
    const start: number = this.state.breaks[pageIndex];
    const end: number = pageIndex + 1 < this.state.breaks.length
      ? this.state.breaks[pageIndex + 1]
      : text.length;
    this.state.pageIndex = pageIndex;
    this.state.offset = start;
    this.state.renderedText = text.substring(start, end);
  }

  /** 整章全局进度：章内页比例 + 章节在书中的比例 */
  private computePercent(): number {
    const total: number = this.state.chapters.length;
    if (total <= 0) {
      return 0;
    }
    const textLength: number = Math.max(1, this.state.getFullText().length);
    const within: number = this.state.offset / textLength;
    return Math.min(1, (this.state.chapterIndex + within) / total);
  }

  /** 每次翻页/滚动后统一提交位置 */
  private commitPosition(): void {
    this.state.percent = this.computePercent();
    this.progress?.updatePosition(this.state.chapterIndex, this.state.offset, this.state.percent);
    this.progress?.markActive();
  }

  // ------------------------------------------------------------ 翻页

  async nextPage(): Promise<void> {
    if (this.state.loading) {
      return;
    }
    if (this.state.settings.pageMode === 'scroll') {
      return; // 滚动模式由 onScroll 上报
    }
    if (this.state.pageIndex >= this.state.pageCount - 1) {
      await this.nextChapter();
      return;
    }
    const nextStart: number = this.state.breaks[this.state.pageIndex + 1];
    this.renderAt(nextStart);
    this.commitPosition();
  }

  async prevPage(): Promise<void> {
    if (this.state.loading) {
      return;
    }
    if (this.state.settings.pageMode === 'scroll') {
      return;
    }
    if (this.state.pageIndex <= 0) {
      await this.prevChapter();
      return;
    }
    this.renderAt(this.state.breaks[this.state.pageIndex - 1]);
    this.commitPosition();
  }

  async nextChapter(): Promise<void> {
    if (!this.state.hasNext) {
      return;
    }
    await this.switchChapter(this.state.chapterIndex + 1, 0);
  }

  async prevChapter(): Promise<void> {
    if (!this.state.hasPrev) {
      return;
    }
    // 回到上一章的最后一页更符合直觉
    await this.switchChapter(this.state.chapterIndex - 1, -1);
  }

  /** 切换章节；toOffset 为 -1 表示定位到末尾 */
  async switchChapter(chapterIndex: number, toOffset: number): Promise<void> {
    await this.progress?.flush(true);
    // 主动跳章时不要沿用"待恢复偏移"
    this.restoreToOffset = -1;
    await this.loadChapter(chapterIndex);
    const offset: number = toOffset < 0
      ? Math.max(0, this.state.getFullText().length - 1)
      : toOffset;
    this.renderAt(offset);
    this.commitPosition();
    await this.progress?.flush(true);
  }

  /** 跳转到目录里的某一章 */
  async jumpToChapter(chapterIndex: number): Promise<void> {
    await this.switchChapter(chapterIndex, 0);
  }

  /** 拖动进度条跳章 */
  async jumpToChapterByPercent(percent: number): Promise<void> {
    const total: number = this.state.chapters.length;
    if (total <= 0) {
      return;
    }
    const chapterIndex: number = Math.min(total - 1, Math.max(0, Math.floor(percent * total)));
    await this.switchChapter(chapterIndex, 0);
  }

  /** 滚动模式：由页面在 onScroll 里上报当前偏移（已节流） */
  reportScrollOffset(offset: number): void {
    const now: number = Date.now();
    if (now - this.lastScrollReportAt < SCROLL_REPORT_INTERVAL_MS) {
      return;
    }
    this.lastScrollReportAt = now;
    this.state.offset = offset;
    this.commitPosition();
  }

  // ------------------------------------------------------------ 设置

  /** 改字号等排版参数：更新设置、清缓存、重新分页并尽量保持相对位置 */
  async updateSettings(next: ReaderSettings): Promise<void> {
    const keepOffset: number = this.state.offset;
    this.state.settings = next;
    SettingsService.getInstance().saveReaderSettings(next);
    if (this.state.book !== null) {
      // 排版变了，旧 key 的缓存不会被命中，这里顺手清掉避免堆积
      await PageCacheRepository.deleteByBook(this.state.book.id);
    }
    await this.buildPagination();
    this.renderAt(keepOffset);
    this.commitPosition();
  }

  toggleMenu(): void {
    this.state.menuVisible = !this.state.menuVisible;
  }

  hideMenu(): void {
    this.state.menuVisible = false;
    this.state.tocVisible = false;
  }

  setTocVisible(visible: boolean): void {
    this.state.tocVisible = visible;
  }

  // ------------------------------------------------------------ 生命周期

  /** 退出阅读页：结算阅读时长并落库 */
  async close(): Promise<void> {
    try {
      if (this.progress !== null) {
        const seconds: number = await this.progress.close();
        if (seconds > 0) {
          await StatsService.submit(this.bookId, seconds);
        }
      }
    } catch (e) {
      Logger.error(LogTag.READ, `退出阅读页结算失败: ${Logger.errText(e as Object)}`);
    }
  }

  /** 切后台：立即落盘进度与阅读时长 */
  async onBackground(): Promise<void> {
    try {
      if (this.progress !== null) {
        const seconds: number = await this.progress.flush(true);
        if (seconds > 0) {
          await StatsService.submit(this.bookId, seconds);
        }
      }
      await SettingsService.getInstance().flushNow();
    } catch (e) {
      Logger.error(LogTag.READ, `切后台落盘失败: ${Logger.errText(e as Object)}`);
    }
  }

  /** 释放资源：必须调用，否则文件句柄泄漏 */
  dispose(): void {
    if (this.readService !== null) {
      this.readService.dispose();
      this.readService = null;
    }
    this.progress = null;
  }

  /** 诊断用：当前是否命中分页缓存 */
  static locatePage(breaks: number[], offset: number): number {
    return PageCache.locatePage(breaks, offset);
  }
}
