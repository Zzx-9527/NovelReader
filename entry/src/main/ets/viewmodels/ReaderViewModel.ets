import { BusinessError } from '@kit.BasicServicesKit';
import { Book } from '../model/Book';
import { Chapter } from '../model/Chapter';
import { Annotation } from '../model/Annotation';
import { ReadingPosition } from '../model/ReadingPosition';
import { ReaderSettings } from '../model/ReaderSettings';
import { PageCache } from '../model/PageCache';
import { ReaderState, BookmarkToggleResult } from './ReaderState';
import { AppState } from '../model/AppState';
import { BookRepository } from '../data/repository/BookRepository';
import { ChapterRepository } from '../data/repository/ChapterRepository';
import { AnnotationRepository } from '../data/repository/AnnotationRepository';
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
  /** 第一页被章节标题占掉的高度（vp）；0 表示本章没有标题 */
  private firstPageExtraHeight: number = 0;
  /**
   * 文字高度测量函数（由页面注入）。
   *
   * 为什么由页面注入而不是 VM 自己调：测量要用 `UIContext.getMeasureUtils()`，
   * 而 `UIContext` 只有组件（页面）能拿到。VM 保持"不碰 UI"的分层约定，
   * 只持有一个函数引用。
   */
  private measure: ((segment: string, width: number) => number) | null = null;
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
  setContentSize(width: number, height: number, firstPageExtraHeight: number = 0): void {
    this.contentWidth = width;
    this.contentHeight = height;
    // 首页要给章节标题让位（分页模式下标题只出现在本章第一页）
    this.firstPageExtraHeight = firstPageExtraHeight;
  }

  /**
   * 注入"文字高度测量"函数（由页面提供，因为它才拿得到 `UIContext`）。
   *
   * 页面给的应当是**原始能力**：`(文本, 可用宽度) => 高度(vp)`，
   * 内部负责 `measureTextSize` 调用与 px→vp 换算。
   * 本类会在其外面再包一层"**先按渲染规则装饰文本、再测量**"，
   * 这样分页量到的高度与屏幕上真正渲染的高度一致。
   */
  setMeasureFn(fn: (segment: string, width: number) => number): void {
    this.measure = fn;
  }

  /** 是否已注入测量函数（诊断用：分页走了实测还是估算） */
  hasMeasureFn(): boolean {
    return this.measure !== null;
  }

  /**
   * 分页专用测量：**先按渲染规则装饰文本，再量高度**。
   *
   * ⚠️ 这一步不能省。渲染端在显示前会做两件事（见 `renderAt`）：
   *   1. 剥掉页首的换行符；
   *   2. 给页内真正的段首行补缩进字符（`indentParagraphHeads`）。
   * 若分页只量**原始文本**，量出的高度就比实际渲染的**小** ——
   * 分页以为还放得下，实际会溢出、末行被裁。
   *
   * 反过来也一样：装饰后再量，分页算的容量与渲染所见完全同源。
   *
   * @param startsMidParagraph 这段文字是否从段落中间开始（决定页首行要不要缩进）
   */
  private measureDecorated(segment: string, width: number,
    startsMidParagraph: boolean): number {
    if (this.measure === null) {
      return 0;
    }
    const fn = this.measure;
    // 与 renderAt 完全相同的装饰顺序：先剥页首换行，再补段首缩进
    let prepared: string = segment;
    let head: number = 0;
    while (head < prepared.length && prepared.charAt(head) === '\n') {
      head++;
    }
    if (head > 0) {
      prepared = prepared.substring(head);
    }
    prepared = ReaderViewModel.indentParagraphHeads(
      prepared, this.state.settings.firstLineIndent, startsMidParagraph);
    return fn(prepared, width);
  }

  /**
   * 用**装饰后**的文本量高度（vp），供页面自检对比。
   *
   * 与分页用的是同一条路径，所以它的结果与 `Text` 实测高度
   * 应当几乎相等 —— 不等就说明渲染端与测量端的规则仍有出入。
   */
  measureHeight(segment: string, width: number): number {
    // 自检对象是"当前这一页已经渲染出来的文本"，
    // 它已经被 renderAt 装饰过了，所以这里传 false 避免二次装饰
    if (this.measure === null) {
      return 0;
    }
    const fn = this.measure;
    return fn(segment, width);
  }

  // ------------------------------------------------------------ 章节加载

  /**
   * 加载并渲染某一章。
   *
   * @param silent true 时不置 loading。
   *   给"章末自动衔接下一章"用：正常切章会闪一下 LoadingView，
   *   而续读最怕的就是这一下中断感（正文区整个换成转圈的占位符）。
   */
  async loadChapter(chapterIndex: number, silent: boolean = false): Promise<void> {
    if (this.readService === null || chapterIndex < 0 || chapterIndex >= this.state.chapters.length) {
      return;
    }
    if (!silent) {
      this.state.loading = true;
    }
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
      this.state.settings, this.contentWidth, this.contentHeight, this.firstPageExtraHeight);

    const cached: number[] = await PageCacheRepository.getBreaks(
      book.id, this.state.chapterIndex, this.layoutKey);
    if (cached.length > 0) {
      Logger.info(LogTag.PAGINATION,
        `分页 cache=HIT 章=${this.state.chapterIndex} 页数=${cached.length}`
          + ` key=${this.layoutKey} 首 3 断点=[${cached[0]},${cached[1]},${cached[2]}]`);
      this.state.breaks = cached;
      this.state.pageCount = cached.length;
      return;
    }

    this.state.repaginating = true;
    try {
      const fullText: string = this.state.getFullText();
      /**
       * 走**实测**分页：把测量函数交给分页服务，由它二分出每页装多少字。
       *
       * 没有测量函数时（理论上不会发生 —— 页面在 `aboutToAppear` 就会注入）
       * 降级到估算版，保证至少能出页面。
       */
      let breaks: number[];
      if (this.measure !== null) {
        /**
         * ⚠️ 传的是 `measureDecorated` 而不是原始测量函数：
         * 分页必须按"**装饰后**的文本"量高度（剥页首换行 + 补段首缩进），
         * 才能与渲染端所见一致。否则量出的高度偏小，页面会溢出。
         */
        breaks = PaginationService.computeBreaksMeasured(
          fullText,
          (seg: string, w: number, mid: boolean): number => this.measureDecorated(seg, w, mid),
          this.contentWidth, this.contentHeight, this.firstPageExtraHeight);
      } else {
        Logger.warn(LogTag.PAGINATION, '未注入测量函数，降级为估算分页（页数可能不准）');
        breaks = PaginationService.computeBreaks(
          fullText, this.state.settings, this.contentWidth, this.contentHeight,
          this.firstPageExtraHeight);
      }
      this.state.breaks = breaks;
      this.state.pageCount = breaks.length;
      await PageCacheRepository.save(book.id, this.state.chapterIndex, this.layoutKey, breaks);
      // 诊断：把"输入尺寸 → 输出断点"一次打全。首 3 个断点的差值 = 首页字符数，
      // 与正文总长对比就能立刻看出首页切得是多是少。
      const firstPageChars: number = breaks.length > 1 ? breaks[1] - breaks[0] : -1;
      Logger.info(LogTag.PAGINATION,
        `分页 cache=MISS 章=${this.state.chapterIndex}`
          + ` 方式=${this.measure !== null ? '实测' : '估算'}`
          + ` 容器=${this.contentWidth.toFixed(0)}x${this.contentHeight.toFixed(0)}`
          + ` 首页让位=${this.firstPageExtraHeight.toFixed(1)}`
          + ` 字号=${this.state.settings.fontSize} 行距=${this.state.settings.lineHeight}`
          + ` 段距=${this.state.settings.paragraphSpacing}`
          + ` 总字数=${fullText.length}`
          + ` 页数=${breaks.length} 首页字数=${firstPageChars}`);
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
      // 滚动模式整章一次渲染：没有"续排页"概念，第一行永远该按段首处理
      this.state.pageStartsMidParagraph = false;
      this.state.renderedText = ReaderViewModel.indentParagraphHeads(
        text, this.state.settings.firstLineIndent, false);
      return;
    }

    const pageIndex: number = PaginationService.locatePage(this.state.breaks, clamped);
    const start: number = this.state.breaks[pageIndex];
    const end: number = pageIndex + 1 < this.state.breaks.length
      ? this.state.breaks[pageIndex + 1]
      : text.length;
    this.state.pageIndex = pageIndex;
    this.state.offset = start;

    // 本页是否从段落中间开始：起始位置不是章首、且前一个字符不是换行
    const midParagraph: boolean = start > 0 && text.charAt(start - 1) !== '\n';
    this.state.pageStartsMidParagraph = midParagraph;
    /**
     * **一律**由 `indentParagraphHeads` 手工补段首缩进，`Text.textIndent` 恒为 0。
     *
     * 为什么不再交给 `textIndent`（这是本轮的关键简化）：
     * `textIndent` 是**全局按 `\n`** 生效的，它无法区分下面这些行 ——
     *   1. 页首的**续行**（上一段没写完的部分）→ 不该缩进；
     *   2. 原文**自带** `　　` 的段首 → 再缩就是 4 格
     *      （表现是"同一页里有些段缩进正常、有些特别大"，本项目实测过）；
     *   3. 真正的段首 → 该缩进。
     * 而 `indentParagraphHeads` 是**逐行**判断的，三种情况一次全对：
     * 跳空行、跳本页第一行（续行）、跳已带前导空白的行，其余补缩进。
     *
     * 代价：每页多一次字符串拼接（几百字符），可忽略。
     */
    /**
     * ⚠️ 兜底：本页文本**开头的换行符**要剥掉。
     *
     * `computeBreaksMeasured` 已经在页边界跳过换行符了，
     * 这里再兜一次是因为**旧的缓存断点**（`layoutKey` 未变时命中）
     * 可能仍带着"页首是 `\n`"的切法 —— 那会渲染成
     * **页面顶部凭空多一个空行**（用户反馈的"有时候顶部空了一行"）。
     * 剥掉它，无论断点怎么来的，页首都不会是空白。
     */
    let pageText: string = text.substring(start, end);
    let trimHead: number = 0;
    while (trimHead < pageText.length && pageText.charAt(trimHead) === '\n') {
      trimHead++;
    }
    if (trimHead > 0) {
      pageText = pageText.substring(trimHead);
    }
    this.state.renderedText = ReaderViewModel.indentParagraphHeads(
      pageText, this.state.settings.firstLineIndent, midParagraph);
  }

  /**
   * 给页内**真正的段首行**补上缩进字符（仅用于渲染）。
   *
   * 为什么不交给 `Text.textIndent`：它是**全局按 `\n`** 生效的，
   * 无法区分"续行"和"段首"，也无法知道原文是否已经自带缩进。
   * 逐行判断才能一次覆盖全部情况：
   *   - 空行 → 不补；
   *   - 本页第一行且本页是**续排**（上一段没写完）→ 不补；
   *   - 本行已带前导空白（原文自带 `　　`）→ 不补，保持原文；
   *   - 其余（真正的段首）→ 补 `firstLineIndent` 个全角空格。
   *
   * @param startsMidParagraph 本页是否从段落中间开始（见 `ReaderState`）
   *
   * ⚠️ 这是在**渲染副本**上做替换，绝不能用它回填 `fullText` ——
   * 字符偏移必须始终以原文为准（进度、分页、将来的书签都依赖它）。
   */
  private static indentParagraphHeads(pageText: string, indentChars: number,
    startsMidParagraph: boolean): string {
    if (indentChars <= 0 || pageText.length === 0) {
      return pageText;
    }
    // 用全角空格拼缩进；不用 String.repeat，避免不同版本的行为差异
    const indentCount: number = Math.max(1, Math.round(indentChars));
    let pad: string = '';
    for (let i = 0; i < indentCount; i++) {
      pad += '　';
    }
    let out: string = '';
    let lineStart: number = 0;
    while (lineStart <= pageText.length) {
      const nl: number = pageText.indexOf('\n', lineStart);
      const isLast: boolean = nl < 0;
      const lineEnd: number = isLast ? pageText.length : nl;
      const line: string = pageText.substring(lineStart, lineEnd);
      const isFirstLine: boolean = lineStart === 0;
      const isBlank: boolean = ReaderViewModel.isBlankLine(line);
      /**
       * 三个"不补"条件，都来自实测踩坑：
       *
       * 1. **本页第一行若是续行，不补**。
       *    本页从段落中间开始时，第一行是上一段没写完的部分 ——
       *    再缩进会让读者误以为"这里新起了一段"。
       *    （若本页恰好从段首开始，`startsMidParagraph` 为 false，
       *     第一行就该缩进，不会被这里跳过。）
       *
       * 2. **本行已带前导空白就不补**。
       *    这本 TXT 部分段落自带 `　　`（全角空格）缩进，
       *    无条件再补一次就是 4 格 —— 表现是"同一页里
       *    有些段缩进正常、有些特别大"。
       *
       * 3. **空行不补**。而且判空**不能用 `trim()`**：
       *    它不认全角空格 `U+3000`，而这本书的"空行"恰好就是全角空格，
       *    用 `trim()` 会把空行当正文行、补上缩进。
       */
      const skipFirst: boolean = isFirstLine && startsMidParagraph;
      const hasLeadingSpace: boolean = line.length > 0
        && ReaderViewModel.isSpaceChar(line.charCodeAt(0));
      const shouldIndent: boolean = !isBlank && !skipFirst && !hasLeadingSpace;
      out += shouldIndent ? pad + line : line;
      if (isLast) {
        break;
      }
      out += '\n';
      lineStart = nl + 1;
    }
    return out;
  }

  /** 单个字符是不是空白（含全角空格等 `trim()` 不认的空白） */
  private static isSpaceChar(c: number): boolean {
    return c === 0x20 || c === 0x09 || c === 0x0D || c === 0x0A
      || c === 0x3000 || c === 0x00A0 || c === 0x2007 || c === 0x202F
      || (c >= 0x2000 && c <= 0x200A)
      || c === 0x200B || c === 0xFEFF;
  }

  /** 整行是否为空白行（判据与 `PaginationService.isBlankLine` 保持一致） */
  private static isBlankLine(line: string): boolean {
    for (let i = 0; i < line.length; i++) {
      if (!ReaderViewModel.isSpaceChar(line.charCodeAt(i))) {
        return false;
      }
    }
    return true;
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

  /**
   * 章末自动衔接下一章（滚动模式用）。
   *
   * 与 `nextChapter()` 的区别只有一处，但很关键：**静默加载**。
   * 滚动模式读到章末时不该出现"正文消失 → 转圈 → 新正文"这一步 ——
   * 那正是"不能无缝衔接"的观感来源。
   *
   * @returns 是否真的切了章；没有下一章时返回 false，页面据此不再重试
   */
  async continueToNextChapter(): Promise<boolean> {
    if (this.state.loading || !this.state.hasNext) {
      return false;
    }
    await this.switchChapter(this.state.chapterIndex + 1, 0, true);
    return true;
  }

  async prevChapter(): Promise<void> {
    if (!this.state.hasPrev) {
      return;
    }
    // 回到上一章的最后一页更符合直觉
    await this.switchChapter(this.state.chapterIndex - 1, -1);
  }

  /** 切换章节；toOffset 为 -1 表示定位到末尾；silent 见 loadChapter */
  async switchChapter(chapterIndex: number, toOffset: number,
    silent: boolean = false): Promise<void> {
    await this.progress?.flush(true);
    // 主动跳章时不要沿用"待恢复偏移"
    this.restoreToOffset = -1;
    await this.loadChapter(chapterIndex, silent);
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

  /**
   * 改字号等排版参数：更新设置、清缓存、重新分页并尽量保持相对位置。
   *
   * ⚠️ 切换**翻页方式**必须重载整章，不能只重算分页：
   * `page` 模式下 `renderedText` 只是当前那一页的文本，
   * 切到 `scroll` 却只重算分页的话，正文区会只显示一页内容 ——
   * 看起来就是"切到滚动模式后整章没了"。
   * 所以这里比对 pageMode 是否变化，变了就整体重载。
   */
  async updateSettings(next: ReaderSettings): Promise<void> {
    const keepOffset: number = this.state.offset;
    const modeChanged: boolean = next.pageMode !== this.state.settings.pageMode;
    this.state.settings = next;
    SettingsService.getInstance().saveReaderSettings(next);

    if (this.state.book !== null) {
      // 排版变了，旧 key 的缓存不会被命中，这里顺手清掉避免堆积
      await PageCacheRepository.deleteByBook(this.state.book.id);
    }

    if (modeChanged) {
      // 让 loadChapter 把位置恢复到当前偏移，而不是章首
      this.restoreToOffset = keepOffset;
      await this.loadChapter(this.state.chapterIndex);
    } else {
      await this.buildPagination();
      this.renderAt(keepOffset);
    }
    this.commitPosition();
  }

  toggleMenu(): void {
    this.state.menuVisible = !this.state.menuVisible;
  }

  hideMenu(): void {
    this.state.menuVisible = false;
    this.state.settingsVisible = false;
  }

  setSettingsVisible(visible: boolean): void {
    this.state.settingsVisible = visible;
  }

  // ------------------------------------------------------------ 书签

  /**
   * 在**当前位置**切换书签。
   *
   * 位置 = 当前章序号 + 当前页起始偏移（`state.offset`）。
   * 若该位置已有书签则删除（软删），否则新增 —— 这样连点两下就是"加了又取消"，
   * 不会攒出重复书签。
   *
   * ⚠️ 为什么放在 ViewModel 而不是页面：`bookId` 与 `state.offset` 都在这里，
   * 页面拿不到 `bookId`（它只从路由参数读一次就丢了）。
   *
   * ⚠️ 返回 `BookmarkToggleResult` 而不是 boolean：见该类型的说明 ——
   * "失败"和"成功取消"都会表现为"当前没书签"，用一个 boolean 会让页面提示错。
   */
  async toggleBookmark(): Promise<BookmarkToggleResult> {
    if (this.bookId <= 0 || this.state.chapterIndex < 0) {
      return BookmarkToggleResult.failed();
    }
    const chapterIndex: number = this.state.chapterIndex;
    const offset: number = this.state.offset;
    try {
      const existing: Annotation | null = await this.findBookmarkAt(chapterIndex, offset);
      if (existing !== null) {
        await AnnotationRepository.softDelete(existing.id);
        return BookmarkToggleResult.removed();
      }
      const id: number = await AnnotationRepository.addBookmark(this.bookId, chapterIndex, offset);
      if (id <= 0) {
        // 章节行不存在时会返回 0（见 addBookmark 的说明），此时没有书签可谈
        return BookmarkToggleResult.failed();
      }
      return BookmarkToggleResult.addedNow();
    } catch (e) {
      Logger.error(LogTag.READ, `切换书签失败: ${Logger.errText(e as Object)}`);
      return BookmarkToggleResult.failed();
    }
  }

  /** 找当前章、当前偏移处是否已有书签；没有返回 null */
  private async findBookmarkAt(chapterIndex: number, offset: number): Promise<Annotation | null> {
    const list: Annotation[] = await AnnotationRepository.listByChapter(this.bookId, chapterIndex);
    for (const item of list) {
      /**
       * ⚠️ 两个条件都不能省：
       *  - `isBookmark()`：同一章里还可能有划线/笔记；
       *  - `startOffset !== null`：`startOffset` 的类型是 `number | null`
       *    （书签允许"只记章首"），先排掉 null 再比数值，避免类型含糊；
       *  - 比对偏移：同一章里可能有**多个**书签（不同页各一个）。
       */
      if (item.isBookmark() && item.startOffset !== null && item.startOffset === offset) {
        return item;
      }
    }
    return null;
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
