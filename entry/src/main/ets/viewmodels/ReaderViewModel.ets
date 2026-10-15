import { BusinessError } from '@kit.BasicServicesKit';
import { Book } from '../model/Book';
import { Chapter } from '../model/Chapter';
import { Annotation } from '../model/Annotation';
import { TextRun } from '../model/TextRun';
import { ReadingPosition } from '../model/ReadingPosition';
import { ReaderSettings } from '../model/ReaderSettings';
import { PageCache } from '../model/PageCache';
import { ReaderState, BookmarkSaveResult, BookmarkDraft } from './ReaderState';
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
import { ThemeApplier } from '../common/theme/ThemeApplier';
import { AppConstants, LogTag } from '../common/constants/AppConstants';
import { Logger } from '../common/utils/Logger';

/** 滚动上报节流（毫秒），避免滚动时疯狂更新状态 */
const SCROLL_REPORT_INTERVAL_MS: number = 200;

/**
 * 分页算好之前，正文占位最多渲染多少字符。
 *
 * ⚠️ 存在的唯一理由：首次打开时分页还没算（要等正文区实测尺寸），
 * 而那一瞬间的占位渲染**不能是整章** —— 编码错的书单章可有上百万字符，
 * 一个百万字符的 `Text` 节点会当场压死主线程（"正文闪一下就卡死"）。
 *
 * 取 3000：远大于一屏能放的字数（约 600 字），视觉上与真实第一页无异；
 * 又小到足以让排版瞬间完成。
 */
const PLACEHOLDER_MAX_CHARS: number = 3000;

/**
 * 单章允许渲染的字符数上限。
 *
 * ⚠️ 超过它就**拒绝渲染并报错**，而不是硬画（见 `loadChapter`）。
 * 依据：正常小说单章几千~几万字；分章失败（编码错）会产生几十万~上百万字的"章"，
 * 那种尺寸的 `Text` 会让 ArkUI 排版压死主线程 —— 表现为白屏闪退，
 * 用户既看不到原因也不知道怎么办。给一条明确提示远好于崩溃。
 */
const MAX_CHAPTER_RENDER_CHARS: number = 200000;

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
    // 全局夜间优先于用户自选的阅读页配色，规则收在 ReaderTheme.of 一处
    return ReaderTheme.of(this.state.settings.theme, ThemeApplier.isDark());
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
      /**
       * ⚠️ 建新 readService 之前**必须先释放旧的**，否则文件句柄泄漏。
       *
       * 为什么这里会重复进入：`ReaderPage` 是 `@Entry`，从书架反复进出会
       * 重建页面 ⇒ 新 VM ⇒ 再次 `open()`。而 `dispose()` 挂在
       * `aboutToDisappear`，某些路径（错误分支、页面被直接销毁）不一定跑到。
       * 每泄漏一个 fd 就少一个可用的；系统 fd 上限很小，
       * 泄漏到几十个之后 `fs.openSync` 开始抛异常 ——
       * 表现是"打开阅读页白屏 / 闪退"，且看不出与进出次数有关。
       *
       * 判据：**持有独占资源的地方，获取前先释放已有实例**，
       * 不要把释放完全托付给生命周期回调。
       */
      if (this.readService !== null) {
        this.readService.dispose();
        this.readService = null;
      }
      this.readService = new ChapterReadService(source, book.encoding, book.id);
      this.progress = new ProgressService(bookId);
      this.progress.markActive();

      /**
       * ⚠️ 清错误必须放在 `restorePosition` **之前**。
       *
       * 早先写在最后一行（`await restorePosition(); ...; error = ''`），
       * 于是 `loadChapter` 在加载过程中设置的**真实错误会被无条件抹掉** ——
       * 包括"章节异常庞大，无法显示"那条提示（见 `loadChapter`）。
       * 抹掉之后页面既没有正文、也没有错误，就是一片空白：
       * 用户看到的正是"白屏"，而且完全无从判断原因。
       *
       * 判据：清除旧状态的语句要放在**产生新状态的操作之前**，
       * 放在之后就会把这次操作的结果一起清掉。
       */
      this.state.error = '';
      await this.restorePosition(book);
      AppState.setCurrentBook(bookId);
      await BookRepository.touchLastRead(bookId);
    } catch (e) {
      this.state.error = `打开失败：${Logger.errText(e as BusinessError)}`;
    } finally {
      this.state.loading = false;
    }
  }

  /**
   * 按进度恢复：定位章节 → 取分页断点 → 算出页码。
   *
   * ⚠️ **章内偏移必须交给 `restoreToOffset` 通道，不能在 `loadChapter` 之后再
   * 补一次 `renderAt()`** —— 这正是"续读总是回到本章第一页"的根因（本项目实测）。
   *
   * 旧实现长这样：
   * ```
   * this.restoreToOffset = pos.offset;
   * await this.loadChapter(chapterIndex);   // 内部已正确 renderAt(pos.offset)
   * if (chapterIndex > 0) {
   *   this.renderAt(0);                     // ← 把刚恢复好的位置又推回章首
   *   return;
   * }
   * this.renderAt(pos.offset);              // 只有第 0 章走这条正确路径
   * ```
   * 于是**除第 0 章以外**的续读全部退回本章第一页。更糟的是 `renderAt` 会把
   * `state.offset` 改写成页起始偏移，而 `loadChapter` 紧接着把它写进
   * `ProgressService` ⇒ 进度不只是"没恢复"，而是被**回退落库**。
   *
   * 判据：`loadChapter` 已经承担"按 `restoreToOffset` 定位"的职责，
   * 调用方**不要**再补一次 `renderAt` —— 同一件事两处实现，后一次必然覆盖前一次
   * （设计文档第 28 条）。
   *
   * ⚠️ 首次打开时正文区尺寸还是 0，`buildPagination` 会提前返回（无断点），
   * 此时 `renderAt` 只把 `state.offset` 记成恢复偏移；真正的分页与定位
   * 发生在尺寸到位后的 `repaginateCurrentChapter()` —— 它会把偏移重新登记回
   * `restoreToOffset`，所以这里不必做任何"预定位"。
   */
  private async restorePosition(book: Book): Promise<void> {
    const pos: ReadingPosition = book.currentPosition();
    const chapterIndex: number = pos.chapterIndex < 0 ? 0 : pos.chapterIndex;
    this.restoreToOffset = book.hasNoProgress() ? 0 : Math.max(0, pos.offset);
    await this.loadChapter(chapterIndex);
    this.state.percent = pos.percent;
  }

  /**
   * 正文区尺寸到位（或变化）后重排当前章，并**保住当前阅读位置**。
   *
   * 为什么必须有这个方法，而不是页面直接调 `loadChapter`：
   * 首次打开时 `setContentSize` 还没被调用，分页算不出来（无断点），
   * 恢复出来的章内偏移只是记在 `state.offset` 上。页面量到尺寸后必须再排一次，
   * 而 `loadChapter` 会**消费掉** `restoreToOffset`（用完置 -1）——
   * 直接调它就会 `renderAt(0)`，把刚恢复的位置推回章首。
   *
   * 所以这里在重排前把 `state.offset` 重新登记回 `restoreToOffset`，
   * 复用既有通道定位（与改字号/刷新页同一条路径），不另写一套定位逻辑。
   *
   * 旋转屏幕、改字号引起的尺寸变化也走这里 —— 于是"转屏后回到第一页"
   * 这个同类问题一并修掉。
   */
  async repaginateCurrentChapter(): Promise<void> {
    if (this.readService === null || this.state.chapterIndex < 0) {
      return;
    }
    /**
     * ⚠️ 已经处于错误态时不要再重排。
     *
     * 页面在正文区尺寸变化时会反复调用本方法，而 `loadChapter` 内部会重新
     * 设置 `loading`/`error`。若前一章是"异常庞大被拒绝渲染"（见 `loadChapter`），
     * 不拦就会变成"loading ↔ error 反复切换"的抖动 ——
     * 用户看到提示一闪一闪，比稳定显示一条错误更糟。
     */
    if (this.state.error.length > 0) {
      return;
    }
    this.restoreToOffset = Math.max(0, this.state.offset);
    await this.loadChapter(this.state.chapterIndex);
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
      /**
       * ⚠️ **异常庞大的章节要明确报错，而不是硬渲染**（"白屏闪退"的兜底防线）。
       *
       * 正常小说的单章在几千到几万字；超过这个量级说明**分章失败**
       * （典型成因是编码选错，见 `ChapterParser.markSuspiciousIfOdd`）。
       * 而一张 `Text` 节点塞进几十万、上百万字符时，ArkUI 的排版会把主线程
       * 彻底压死 —— 用户看到的是"正文闪一下然后卡死/被系统杀掉"，
       * 既没有错误提示、也不知道该做什么。
       *
       * 所以这里直接拒绝渲染，给一条**可操作**的提示。这比白屏好得多：
       * 用户知道该去书架长按这本书换编码重新分章。
       *
       * 阈值取 20 万字符：是正常章节上限（几万字）的数倍，不会误伤；
       * 又远低于分章失败产生的量级（几十万~上百万）。
       */
      if (text.length > MAX_CHAPTER_RENDER_CHARS) {
        this.state.setFullText('');
        this.state.renderedText = '';
        this.state.chapterIndex = chapterIndex;
        this.state.chapterTitle = chapter.title;
        Logger.warn(LogTag.READ,
          `章节异常庞大（${text.length} 字符），拒绝渲染以免主线程被排版压死：`
            + `book=${this.bookId} chapter=${chapterIndex}`);
        this.state.error = `这一章有 ${text.length} 个字，远超正常章节`
          + `（说明分章可能失败），无法显示。请返回书架长按这本书，`
          + `换一个编码重新分章后再读。`;
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
      /**
       * ⚠️ 划线必须**在渲染之前**取回来。
       *
       * `renderAt` 之后页面立刻会调 `buildTextRuns` 去画底纹，
       * 若此时 `state.highlights` 还是旧章的，新章正文会带上一批
       * 不相干的高亮 —— 看起来像数据错乱，而其实只是时序问题。
       *
       * ⚠️ 失败**不改变章节加载结果**：划线是增强，取不到就是"这一章没有高亮"，
       * 绝不该因为一次查询失败而让用户读不了书。所以单独 try、只清空不抛错。
       */
      await this.reloadHighlights();
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
       * 选路：**正常章走实测分页，超大章走估算分页**。
       *
       * ⚠️ 超大章必须降级（否则就是"白屏假死"）：
       * 实测分页每页约 9 次 `measureTextSize` 系统调用，
       * 而兜底切分产生的大章（几十万字 = 几百页）意味着**数千次同步测量**，
       * 主线程被按住数十秒 ⇒ 系统判定无响应 ⇒ 用户看到"正在打开…"永远转圈。
       * 估算版精度有已知缺陷，但它 O(n) 且不调系统 API —— 能翻页优先。
       */
      let breaks: number[];
      const tooLarge: boolean = PaginationService.isTooLargeForMeasured(fullText);
      if (this.measure !== null && !tooLarge) {
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
        if (tooLarge) {
          Logger.warn(LogTag.PAGINATION,
            `章节过大（${fullText.length} 字 > 上限），降级为估算分页以避免主线程被测量调用压死`);
        } else {
          Logger.warn(LogTag.PAGINATION, '未注入测量函数，降级为估算分页（页数可能不准）');
        }
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
          + ` 方式=${this.measure !== null && !tooLarge ? '实测' : '估算'}`
          + ` 容器=${this.contentWidth.toFixed(0)}x${this.contentHeight.toFixed(0)}`
          + ` 首页让位=${this.firstPageExtraHeight.toFixed(1)}`
          + ` 字号=${this.state.settings.fontSize} 行距=${this.state.settings.lineHeight}`
          + ` 字距=${this.state.settings.letterSpacing}`
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
      /**
       * ⚠️ **分页模式 + 断点还没算出来**时，这里只允许渲染一小段，绝不能整章。
       *
       * 这是"正文闪一下就卡死/闪退"的根因（用户实测）：
       * 首次打开时 `breaks` 必然是空的（分页要等正文区实测尺寸），
       * 而这一分支会把**整章**塞进 `renderedText` —— 正常章节几千字无所谓，
       * 但编码错的书单章可达上百万字符，`Text` 要为一个百万字符节点做排版，
       * 主线程当场被压死。表现为"正文闪一下（首帧已提交）然后卡住/被杀"。
       *
       * 所以这里按"一屏最多能放的字数"截断：它只是**分页完成前的占位**，
       * 紧接着的 `repaginateCurrentChapter()` 会把真正的第一页换上来。
       * 截断不影响任何偏移口径 —— 进度、书签用的仍是 `fullText`。
       *
       * ⚠️ 只有**分页模式**才截断：滚动模式本来就是整章滚动，
       * 截断会让用户看不到后半章（那是另一类 bug）。
       */
      if (this.state.settings.pageMode === 'scroll') {
        this.state.renderedText = ReaderViewModel.indentParagraphHeads(
          text, this.state.settings.firstLineIndent, false);
        return;
      }
      const placeholder: string = text.length > PLACEHOLDER_MAX_CHARS
        ? text.substring(0, PLACEHOLDER_MAX_CHARS)
        : text;
      this.state.renderedText = ReaderViewModel.indentParagraphHeads(
        placeholder, this.state.settings.firstLineIndent, false);
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
    /**
     * ⚠️ 快路径：没有换行就无事可做（既没有段首、也没有空行）。
     *
     * ⚠️ 判据**不能**写成"缩进为 0 就返回"：本函数同时负责**逐行**判断
     * 段首（跳过空行、跳过续行、跳过已带前导空白的行），
     * 缩进为 0 只是"补 0 个空格"，但仍然要走一遍逐行逻辑 ——
     * 否则将来任何"逐行"的装饰都会被这个提前返回静默吃掉。
     */
    if (pageText.length === 0 || pageText.indexOf('\n') < 0) {
      return pageText;
    }
    /**
     * 缩进字符数。
     *
     * ⚠️ 必须是 `Math.max(0, ...)` 而**不是** `Math.max(1, ...)`：
     * 后者会把"缩进 0"强行变成 1 个全角空格，**用户把滑块拖到 0 却没反应**
     * （这正是用户实测反馈的问题之一）。0 是合法值，表示"段首不缩进"。
     *
     * ⚠️ 但 `pad` 为空串时不能让 `shouldIndent` 真的生效去拼一个空串 ——
     * 那虽然结果一样（拼空串等于没拼），却会白走一遍字符串拼接。
     * 所以下面用 `indentCount > 0` 一并把它挡住。
     */
    const indentCount: number = Math.max(0, Math.round(indentChars));
    let pad: string = '';
    for (let i = 0; i < indentCount; i++) {
      pad += '　';
    }
    let out: string = '';
    let lineStart: number = 0;
    /**
     * 上一行是否"开着段落"（有内容的行）。
     *
     * ⚠️ 与 `PaginationService.prevLineOpen` 同义：段首的判据是
     * "本行有内容、且上一行没有开着段落"。
     *
     * ⚠️ **段距设置已整个移除**（见 `SettingsPanel` 的说明：ArkUI 没有
     * 段落间距属性，段距只能插整数个空行 ⇒ 滑块上只有 0.25 一档有效，
     * 中间全是死区）。所以本函数**不再插入任何段距空行**、
     * 也**不再吃掉**原文空行 —— 空行原样输出、自己占 1 行，
     * 段落之间的空隙就由它承担。见下面 `isBlank` 分支的说明。
     */
    let prevLineOpen: boolean = false;
    while (lineStart <= pageText.length) {
      const nl: number = pageText.indexOf('\n', lineStart);
      const isLast: boolean = nl < 0;
      const lineEnd: number = isLast ? pageText.length : nl;
      const line: string = pageText.substring(lineStart, lineEnd);
      const isFirstLine: boolean = lineStart === 0;
      const isBlank: boolean = ReaderViewModel.isBlankLine(line);
      /**
       * 三个"不补缩进"条件，都来自实测踩坑：
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
      const shouldIndent: boolean = !isBlank && !skipFirst && !hasLeadingSpace
        && indentCount > 0;

      /**
       * ⚠️ **不再有段距逻辑**：段距设置已移除。
       *
       * 空行**原样输出**（它自己就是一次换行、占满一行），
       * 段落之间的空隙因此由**原文的空行**承担 ——
       * 与 `PaginationService` 的 `wrappedLines = 1`（空行占 1 行）
       * 严格对应。两侧口径一致是硬要求：不一致就会裁掉正文末尾。
       */
      out += shouldIndent ? pad + line : line;

      prevLineOpen = !isBlank;

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
      /**
       * 第一页向回翻 → 落到**上一章的末尾**（`switchChapter` 的 toOffset = -1 语义），
       * "接着刚才读的地方继续往前读"。
       *
       * ⚠️ 不能复用 `prevChapter()`：那是「上一章」按钮的语义，
       * 按用户定案它落到**上一章章首**（想从开头重看）。
       * 翻页回退与按钮跳章是两个不同的动作，各走各的定位 ——
       * 早期两者共用，表现为"第 2 章第 1 页点左边直接跳到第 1 章开头"。
       */
      if (!this.state.hasPrev) {
        return;
      }
      await this.switchChapter(this.state.chapterIndex - 1, -1);
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

  /**
   * 上一章。
   *
   * ⚠️ 定位目标是**章首**（= 上一章的标题行），**不是章末**。
   *
   * 早期实现传 `-1`（= 章末），理由是"往回翻的直觉是落在上一章最后"。
   * 用户实测反馈这不符合预期：按「上一章」是想**从上一章开头重读/回看**，
   * 落在末尾等于"倒着读"，还得自己再滚到顶。
   *
   * ⚠️ 顺带解决了滚动模式的一个连带问题：章末定位要靠
   * `scrollEdge(Edge.Bottom)`，而它离章末极近，会被
   * `shouldContinueToNextChapter()` 判成"读到章末" ⇒ **自动衔接回下一章**，
   * 表现就是"按上一章刚回去、立刻被弹回来"。回到章首就没有这个风险。
   */
  async prevChapter(): Promise<void> {
    if (!this.state.hasPrev) {
      return;
    }
    // 0 = 章首，与"下一章"（也是 0）对称：换章一律从这一章的开头开始
    await this.switchChapter(this.state.chapterIndex - 1, 0);
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

  /**
   * 刷新当前阅读页（顶栏"⟳"按钮）。
   *
   * 做什么：丢掉**本章的正文解码缓存**与**本书的全部分页缓存**，
   * 重新从文件读取当前章、重新分页，并尽量停在原来的位置。
   *
   * 为什么需要它：正文来自原文件，分页结果来自 `page_cache`。
   * 若文件在外部被改动过、或分页缓存与当前代码不一致
   * （典型症状就是"排版看起来不对、但怎么调设置都没用"），
   * 用户需要一个**不必退出阅读页**的自救入口 —— 这正是这个按钮。
   *
   * ⚠️ 保留 `state.offset` 而不是回到章首：刷新是"重排"，
   * 不是"重新开始读"。把位置丢了用户会以为进度被清了。
   * 复用 `restoreToOffset` 这条既有通道（与改字号/换翻页方式同一条路径），
   * 不另写一套定位逻辑 —— 避免"同一件事两个实现"（设计文档第 28 条）。
   *
   * ⚠️ 分页缓存必须**整本**删而不是只删当前章：
   * 重排后各章断点可能都变（尤其算法版本变了），
   * 只删当前章会让翻到下一章时命中旧断点，出现"这章对、下章又不对"。
   */
  async refreshCurrentChapter(): Promise<void> {
    if (this.readService === null || this.state.chapterIndex < 0) {
      return;
    }
    const keepOffset: number = this.state.offset;
    this.state.loading = true;
    try {
      // ① 正文解码缓存：不清就会把旧文件内容再读一遍
      this.readService.clearCache();
      // ② 分页缓存：整本清，理由见上
      if (this.state.book !== null) {
        await PageCacheRepository.deleteByBook(this.state.book.id);
      }
      // ③ 走既有恢复通道定位回原处，再重载本章
      this.restoreToOffset = keepOffset;
      await this.loadChapter(this.state.chapterIndex);
      this.state.error = '';
    } catch (e) {
      this.state.error = `刷新失败：${Logger.errText(e as BusinessError)}`;
    } finally {
      this.state.loading = false;
    }
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

  /**
   * 切换**整个应用**的深浅色（菜单底栏"夜间"入口）。
   *
   * ⚠️ 这与 `updateSettings()` 改的**不是一回事**（用户明确指出的区别）：
   *  - 本方法 → 应用级主题，走系统 `setColorMode`，
   *    颜色来自 `resources/base|dark/element/color.json`，
   *    影响书架、"我的"以及所有用 `AppColor` 的界面；
   *  - `updateSettings()` 的 `settings.theme` → 只改**阅读页正文背景**
   *    （浅色/羊皮纸/护眼/夜间）。
   *
   * 所以这里**绝不**碰 `settings.theme`：混在一起的话，
   * 用户选了护眼绿、再点"夜间"，正文背景会被一起改成黑底 —— 那不是他想要的。
   *
   * ⚠️ 顺序是「先应用、再落盘」（设计文档 5.7.5 第 4 条）：
   * 反过来的话 `setColorMode` 一旦失败，设置已经存下，下次启动才生效，
   * 用户看到"点了没反应，重启以后变了"。
   *
   * @returns 是否切换成功
   */
  toggleAppTheme(): boolean {
    const next: number = ThemeApplier.nextToggleMode();
    if (!ThemeApplier.applyMode(next)) {
      return false;
    }
    // 应用成功才落盘
    SettingsService.getInstance().putAppThemeMode(next);
    return true;
  }

  hideMenu(): void {
    this.state.menuVisible = false;
    this.state.settingsVisible = false;
  }

  setSettingsVisible(visible: boolean): void {
    this.state.settingsVisible = visible;
  }

  setBookmarkVisible(visible: boolean): void {
    this.state.bookmarkVisible = visible;
  }

  // ------------------------------------------------------------ 书签

  /**
   * 组装书签弹窗所需的草稿（长按选中后调用）。
   *
   * @param startOriginal 选区起点（**原文**偏移，页面须先用 `toOriginalOffset` 换算）
   * @param endOriginal 选区终点（**原文**偏移）；与起点相同表示只记一个点
   *
   * ⚠️ 选文必须从**原文**里截取，不能从 `renderedText` 里截 ——
   * 后者含装饰插入的缩进空格，存进去的"选中内容"会凭空多出全角空格。
   * 这也是为什么这里要接收原文偏移而不是渲染下标。
   */
  buildBookmarkDraft(startOriginal: number, endOriginal: number): BookmarkDraft {
    const draft = new BookmarkDraft();
    const text: string = this.state.getFullText();
    const maxIndex: number = Math.max(0, text.length - 1);
    const start: number = Math.max(0, Math.min(startOriginal, maxIndex));
    const end: number = Math.max(start, Math.min(endOriginal, text.length));
    draft.startOffset = start;
    draft.endOffset = end > start ? end : -1;
    // 从原文截取选中的内容（端点是开区间，substring 正好符合）
    draft.selectedText = text.substring(start, end);
    draft.chapterLabel = this.state.chapterTitle.length > 0
      ? this.state.chapterTitle
      : `第 ${this.state.chapterIndex + 1} 章`;
    return draft;
  }

  /**
   * 保存书签（弹窗点"保存"时调用）。
   *
   * ⚠️ 与旧版"点一下即切换"的区别：这条路径会带上**选文**与**备注**，
   * 且同一位置已有书签时做**覆盖**（软删旧的再新增），
   * 保证库里存的就是用户在弹窗里确认的那一份。
   */
  async saveBookmark(draft: BookmarkDraft): Promise<BookmarkSaveResult> {
    if (this.bookId <= 0 || this.state.chapterIndex < 0) {
      return BookmarkSaveResult.failed();
    }
    const chapterIndex: number = this.state.chapterIndex;
    try {
      const existing: Annotation | null = await this.findBookmarkAt(chapterIndex, draft.startOffset);
      if (existing !== null) {
        /**
         * ⚠️ 同位置已有书签时，**先软删再新增**，而不是只 `updateNote`。
         *
         * 只更新备注会漏掉"选文变了"的情况（用户在同一起点重新选了另一段），
         * 库里就会留着旧的 `selected_text` —— 与用户在弹窗里确认的内容不一致。
         * 软删 + 新增保证存下来的**就是**用户刚确认的那一份，
         * 且因为旧行已标记删除，列表里不会出现两条。
         */
        await AnnotationRepository.softDelete(existing.id);
      }
      const id: number = await AnnotationRepository.add(
        this.bookId, chapterIndex, AppConstants.ANNOTATION_BOOKMARK,
        draft.startOffset,
        draft.endOffset >= 0 ? draft.endOffset : null,
        draft.selectedText, draft.note, '');
      if (id <= 0) {
        return BookmarkSaveResult.failed();
      }
      return BookmarkSaveResult.saved(existing !== null);
    } catch (e) {
      Logger.error(LogTag.READ, `保存书签失败: ${Logger.errText(e as Object)}`);
      return BookmarkSaveResult.failed();
    }
  }

  /**
   * 取**原文**中 `[start, end)` 区间的文字（供复制/书签使用）。
   *
   * ⚠️ 必须从原文取，不能从 `renderedText` 取：后者含装饰插入的全角缩进空格，
   * 复制出去的内容会凭空多出空格。两个入参都应是**原文偏移**
   * （页面侧先用 `toOriginalOffset` 换算）。
   */
  originalTextBetween(startOriginal: number, endOriginal: number): string {
    const text: string = this.state.getFullText();
    const start: number = Math.max(0, Math.min(startOriginal, text.length));
    const end: number = Math.max(start, Math.min(endOriginal, text.length));
    return text.substring(start, end);
  }

  // ------------------------------------------------------------ 划线 / 笔记

  /**
   * 保存一条划线（长按选中 → 菜单「划线」）。
   *
   * ⚠️ 入参是**原文偏移**（页面侧先用 `toOriginalOffset` 换算）：
   * 划线的区间将来要用来在正文里找位置，必须与进度/书签同一套坐标。
   *
   * @returns 新增的标注 id；<=0 表示失败
   */
  async addHighlight(startOriginal: number, endOriginal: number): Promise<number> {
    if (this.bookId <= 0 || this.state.chapterIndex < 0) {
      return 0;
    }
    const text: string = this.originalTextBetween(startOriginal, endOriginal);
    // 没有实际选中内容就不写：空划线在列表里是一行无法理解的空记录
    if (text.length === 0) {
      return 0;
    }
    try {
      const id: number = await AnnotationRepository.addHighlight(
        this.bookId, this.state.chapterIndex, startOriginal, endOriginal,
        text, AppConstants.HIGHLIGHT_DEFAULT_COLOR);
      /**
       * ⚠️ 写入成功后**立刻重取划线**，否则新划的那一段要等下次换章才显示。
       *
       * 这正是本功能之前"划了线什么都看不见"的残留部分：数据已经进库，
       * 但内存里的 `state.highlights` 还是旧的，正文自然画不出新底纹。
       * 用户会以为划线失败、再划一次，于是库里留下重复记录。
       *
       * ⚠️ 重取失败**不影响返回值**：标注已经写进去了，不该因为
       * 一次刷新失败就报告"划线失败"（那是谎报，会让用户重复操作）。
       */
      if (id > 0) {
        await this.reloadHighlights();
      }
      return id;
    } catch (e) {
      Logger.error(LogTag.READ, `保存划线失败: ${Logger.errText(e as Object)}`);
      return 0;
    }
  }

  /**
   * 保存一条笔记（长按选中 → 菜单「笔记」→ 填内容）。
   *
   * ⚠️ **笔记内容要求非空**（与划线、书签都不同）：
   * 一条没有内容的"笔记"在笔记列表里什么都看不到，等于产生垃圾数据；
   * 用户真想只标位置，应该用书签或划线。
   *
   * @returns 新增的标注 id；<=0 表示失败
   */
  async addNote(startOriginal: number, endOriginal: number, noteContent: string): Promise<number> {
    if (this.bookId <= 0 || this.state.chapterIndex < 0) {
      return 0;
    }
    const trimmed: string = noteContent.trim();
    if (trimmed.length === 0) {
      return 0;
    }
    const text: string = this.originalTextBetween(startOriginal, endOriginal);
    try {
      return await AnnotationRepository.addNote(
        this.bookId, this.state.chapterIndex, startOriginal, endOriginal,
        text, trimmed, AppConstants.HIGHLIGHT_DEFAULT_COLOR);
    } catch (e) {
      Logger.error(LogTag.READ, `保存笔记失败: ${Logger.errText(e as Object)}`);
      return 0;
    }
  }

  /**
   * 组装"划线/笔记"弹窗所需的草稿（复用书签那套）。
   *
   * ⚠️ 与 `buildBookmarkDraft` 共用 `BookmarkDraft` 而不是另建一个类：
   * 三者需要展示的东西完全一样（章节名 + 选文 + 备注），
   * 多一个类就多一份要同步维护的字段。
   */
  buildAnnotationDraft(startOriginal: number, endOriginal: number): BookmarkDraft {
    return this.buildBookmarkDraft(startOriginal, endOriginal);
  }

  /**
   * 把**渲染文本（`renderedText`）的下标**换算成**原文偏移**。
   *
   * ⚠️ 为什么必须换算：长按选中回调给的 `TextRange` 下标是相对
   * **渲染出来的那段文字**的，而渲染前做过**两步**装饰（见 `renderAt`
   * 与 `indentParagraphHeads`）：
   *   1. 剥掉页首换行；
   *   2. 给段首补了 `firstLineIndent` 个全角空格。
   * 书签与进度一律以**原文偏移**为准（设计文档铁律 5.1）。
   * 直接把渲染下标存进去，书签就会落到错误位置 —— 缩进越多偏得越远。
   *
   * ⚠️ 为什么用"双游标对齐"而不是重建一遍缩进逻辑：
   * 重建就等于把 `indentParagraphHeads` 的判断抄第二份，
   * 将来改了一处忘了另一处，偏移就会**静默**错位（本项目已在
   * "测量与渲染不同源"上踩过同类坑，见 pitfall 57/59）。
   * 而 `state.renderedText` 本身就是装饰后的**唯一真相**，
   * 拿它跟原文片段直接对齐，天然与装饰实现同步。
   *
   * 原理：装饰只**插入**字符（缩进），从不删除或改写原文，
   * 所以两个游标错位时，一定是渲染侧多了一个插入字符 —— 只推渲染游标即可。
   * 插入位置必然是行首，而"行首已带空白就不插"这条规则保证：
   * 插入的空白字符**不会**与原文该位置的字符相同，因此不会误判。
   */
  toOriginalOffset(renderedIndex: number): number {
    const text: string = this.state.getFullText();
    const rendered: string = this.state.renderedText;
    if (rendered.length === 0 || renderedIndex <= 0) {
      return this.pageRawStart();
    }

    // 取本页**原文片段**：起点算法与 renderAt 完全一致（含剥页首换行）
    const head: number = this.pageRawStart();
    let end: number = text.length;
    if (this.state.settings.pageMode !== 'scroll' && this.state.breaks.length > 0) {
      const pageIndex: number = this.state.pageIndex;
      end = pageIndex + 1 < this.state.breaks.length
        ? this.state.breaks[pageIndex + 1]
        : text.length;
    }
    const raw: string = text.substring(head, end);

    let i: number = 0;
    let j: number = 0;
    const limit: number = Math.min(renderedIndex, rendered.length);
    while (i < limit && j < raw.length) {
      if (rendered.charAt(i) === raw.charAt(j)) {
        i++;
        j++;
      } else {
        // 渲染侧多出来的那个字符 = 装饰插入的缩进，原文里没有对应物
        i++;
      }
    }
    return head + j;
  }

  /** 本页渲染文本在**原文**里的起始偏移（含"剥页首换行"，与 renderAt 同源） */
  private pageRawStart(): number {
    if (this.state.settings.pageMode === 'scroll' || this.state.breaks.length === 0) {
      return 0;
    }
    const text: string = this.state.getFullText();
    const pageIndex: number = this.state.pageIndex;
    const start: number = this.state.breaks[pageIndex];
    const end: number = pageIndex + 1 < this.state.breaks.length
      ? this.state.breaks[pageIndex + 1]
      : text.length;
    let head: number = start;
    while (head < end && text.charAt(head) === '\n') {
      head++;
    }
    return head;
  }

  /**
   * 本页**原文片段**的区间 `[start, end)`。
   *
   * ⚠️ 与 `toOriginalOffset` / `pageRawStart` 取的是**同一段**：
   * 起点要剥掉页首换行（与 `renderAt` 一致），终点在本页断点处。
   * 三处必须同源，否则分段结果与偏移换算会各说各话。
   */
  private pageRawRange(): number[] {
    const text: string = this.state.getFullText();
    const head: number = this.pageRawStart();
    let end: number = text.length;
    if (this.state.settings.pageMode !== 'scroll' && this.state.breaks.length > 0) {
      const pageIndex: number = this.state.pageIndex;
      end = pageIndex + 1 < this.state.breaks.length
        ? this.state.breaks[pageIndex + 1]
        : text.length;
    }
    return [head, end];
  }

  /**
   * 重新加载**当前章**的划线，供正文画底纹。
   *
   * ⚠️ `listByChapter` 返回的是**本章全部标注**（书签 + 划线 + 笔记），
   * 这里按 `isHighlight()` 过滤后才存进 `state.highlights`。
   * 不过滤的话书签与笔记也会进正文分段逻辑 —— 书签没有区间（`isChapterOnly`）、
   * 笔记虽有区间但不该上色，两者都会让高亮出现在不该出现的位置。
   *
   * ⚠️ 查询失败**只清空、不抛错**：正文能否渲染不能依赖一次装饰性查询。
   */
  async reloadHighlights(): Promise<void> {
    if (this.bookId <= 0 || this.state.chapterIndex < 0) {
      this.state.highlights = [];
      return;
    }
    try {
      const all: Annotation[] =
        await AnnotationRepository.listByChapter(this.bookId, this.state.chapterIndex);
      const only: Annotation[] = [];
      for (const item of all) {
        if (item.isHighlight() && !item.isChapterOnly()) {
          only.push(item);
        }
      }
      this.state.highlights = only;
    } catch (e) {
      this.state.highlights = [];
      Logger.warn(LogTag.READ, `加载划线失败，正文不画底纹: ${Logger.errText(e as BusinessError)}`);
    }
  }

  /**
   * 供页面在**新增 / 删除划线之后**刷新底纹。
   *
   * ⚠️ 只重取数据，**不重排、不动分页**：划线只影响 `Span` 的底色，
   * 不影响任何字符的宽度与高度，所以不需要重新分页
   * （重排反而会让用户当前的位置跳一下，代价远大于收益）。
   */
  async refreshHighlights(): Promise<void> {
    await this.reloadHighlights();
  }

  /**
   * 把当前渲染的正文切成「普通段 / 高亮段」交替的片段列表，供阅读页用 `Span` 画出划线底色。
   *
   * ## 核心约束：拼接结果**必须**等于 `renderedText`
   *
   * 这是本方法的正确性判据，也是它敢用的前提：所有片段按顺序拼起来
   * 与原来的整段字符串**逐字符相同** ⇒ 排版结果与改动前完全一致，
   * 分页不受任何影响（只是把 `Text` 的一个字符串子节点换成了多个 `Span`）。
   * 为此本方法**只做切分、不做任何字符增删**。
   *
   * ## 怎么把"原文偏移"映射到"渲染下标"
   *
   * 渲染文本 = 原文片段经过两步装饰（见 `renderAt`）：剥页首换行 + 段首补缩进。
   * 装饰**只插入字符、从不改写**，所以用与 `toOriginalOffset` 相同的
   * **双游标对齐**算法正着走一遍：两个游标同步前进，
   * 字符相同则一起前进，不同则说明渲染侧多了一个插入的缩进字符。
   *
   * ⚠️ 刻意**不重建缩进逻辑**（不去重新判断哪里是段首）：
   * 重建等于把 `indentParagraphHeads` 抄第二份，改一处忘另一处就会
   * **静默**错位（设计文档记过同类坑）。这里拿"已经装饰好的 renderedText"
   * 当唯一真相去对齐，天然与装饰实现同步。
   *
   * @param highlights 当前章的全部划线（**只传划线**，书签/笔记不参与）
   */
  buildTextRuns(highlights: Annotation[]): TextRun[] {
    const rendered: string = this.state.renderedText;
    if (rendered.length === 0) {
      return [];
    }

    const range: number[] = this.pageRawRange();
    const head: number = range[0];
    const raw: string = this.state.getFullText().substring(head, range[1]);

    /**
     * 先把每个划线区间换算成**渲染下标**区间，再合并重叠区间。
     *
     * ⚠️ 合并是必要的，不是优化：同一段文字上可能有多条划线
     * （用户重复划、或两条相邻），不合并就会出现互相嵌套的区间，
     * 切分时后一条会把前一条切断、生成大量零碎片段（`Span` 数量暴涨）。
     * 合并后每个字符最多属于一个高亮区间，切分天然干净。
     *
     * 区间用 `[start, end)` 半开表示，与分页断点的口径一致。
     */
    const spans: number[][] = [];
    /**
     * 渲染下标 → 原文偏移 的对照表：`renderedIndexOfRaw[k]` = 原文片段里
     * 第 k 个字符在**渲染文本**中的下标。
     *
     * ⚠️ 用"原文下标 → 渲染下标"这个方向建表（不是反过来），因为待换算的
     * 划线区间给的是**原文偏移**；建好表就能 O(1) 查两端点。
     * 未被赋值的位置（对应被插入字符"顶掉"的偏移）由 `lookupRendered` 兜底。
     */
    const renderedIndexOfRaw: number[] = [];

    /**
     * 单趟双游标对齐。与 `toOriginalOffset` 是**同一个算法、同一个方向假设**：
     * 渲染文本只比原文**多**插入字符（段首缩进 + 段距空行），从不改写或删除，
     * 所以两游标字符不同时，一定是渲染侧那个字符是插入的 —— 只推渲染游标。
     *
     * ⚠️ 段距空行（`indentParagraphHeads` 插入的 `\n`）会不会被误配成原文的 `\n`？
     * 不会 —— 但这是**依赖插入位置**的，值得写清楚为什么：
     * 插入发生在"某个段落的**第一行之前**"，而此刻游标已经走过了上一行末尾那个
     * `\n`（它在上一轮就被消费掉了），于是插入的 `\n` 面对的是该段的**首字符**
     * （不是 `\n`），必然判为不同 ⇒ 被正确识别成插入字符。
     *
     * 反过来说：**若将来把段距改成插在"行尾之后"**，插入的 `\n` 就会撞上原文
     * 那个 `\n` 而被判成"匹配"，两个游标从此错位一格、整页高亮全部偏一位。
     * 改插入位置时**必须**回来重看这一条。
     *
     * ⚠️ 循环条件写成两个独立的 `while` 边界判断、不用 `break`：
     * 用 `break` 时"最后一次相等推进"可能来不及记账，
     * 于是页面最后一个字符永远查不到下标，高亮会在行尾**短一截**。
     */
    let i: number = 0;
    let j: number = 0;
    while (i < rendered.length) {
      if (j < raw.length && rendered.charAt(i) === raw.charAt(j)) {
        renderedIndexOfRaw[j] = i;
        i++;
        j++;
      } else if (j < raw.length) {
        // 渲染侧多出来的插入字符（缩进）：不属于任何原文偏移
        i++;
      } else {
        // 原文片段已走完，剩下的渲染字符都是插入的，无需记账
        break;
      }
    }

    for (const item of highlights) {
      if (!item.isHighlight() || item.isChapterOnly()) {
        continue;
      }
      const s: number | null = item.startOffset;
      const e: number | null = item.endOffset;
      if (s === null || e === null || e <= s) {
        continue;
      }
      // 原文偏移 → 本页内的相对下标
      const relStart: number = s - head;
      const relEnd: number = e - head;
      // 与本页无交集（别的页上的划线）
      if (relEnd <= 0 || relStart >= raw.length) {
        continue;
      }
      const clampedStart: number = relStart < 0 ? 0 : relStart;
      const clampedEnd: number = relEnd > raw.length ? raw.length : relEnd;

      const rs: number = ReaderViewModel.lookupRendered(renderedIndexOfRaw, clampedStart, rendered.length);
      const re: number = ReaderViewModel.lookupRendered(renderedIndexOfRaw, clampedEnd, rendered.length);
      if (re <= rs) {
        continue;
      }
      spans.push([rs, re]);
    }

    if (spans.length === 0) {
      // 没有划线：**返回单个普通片段**，而不是空数组 ——
      // 空数组会让调用方渲染出空白正文
      return [new TextRun(rendered, false)];
    }

    // 按起点排序后合并重叠/相接区间
    spans.sort((a: number[], b: number[]): number => a[0] - b[0]);
    const merged: number[][] = [];
    for (const span of spans) {
      const last: number[] | undefined = merged.length > 0 ? merged[merged.length - 1] : undefined;
      if (last !== undefined && span[0] <= last[1]) {
        if (span[1] > last[1]) {
          last[1] = span[1];
        }
      } else {
        merged.push([span[0], span[1]]);
      }
    }

    /**
     * 按合并后的区间切分。
     *
     * ⚠️ 用 `substring` 顺序拼接，**不做 trim、不做任何字符替换** ——
     * 拼接结果必须与 `rendered` 逐字符相同（见方法注释的核心约束）。
     */
    const runs: TextRun[] = [];
    let cursor: number = 0;
    for (const m of merged) {
      const start: number = m[0] < 0 ? 0 : m[0];
      const end: number = m[1] > rendered.length ? rendered.length : m[1];
      if (start > cursor) {
        runs.push(new TextRun(rendered.substring(cursor, start), false));
      }
      if (end > start) {
        runs.push(new TextRun(rendered.substring(start, end), true));
      }
      cursor = end > cursor ? end : cursor;
    }
    if (cursor < rendered.length) {
      runs.push(new TextRun(rendered.substring(cursor), false));
    }
    return runs;
  }

  /**
   * 查"原文偏移 k 对应的渲染下标"。
   *
   * ⚠️ 两个边界都要处理：
   *  - `k` 落在页面末尾之后（划线终点超出本页）→ 取 `renderedLength`，
   *    表示"一直到本页结束都高亮"；
   *  - 表里没有记录（该偏移对应的字符被插入字符挤掉、没走到）→
   *    向前找最近一个有效值；找不到就用 0。**不能返回 undefined**，
   *    否则切分时会出现 `NaN` 下标、`substring` 静默返回错内容。
   */
  private static lookupRendered(table: number[], k: number, renderedLength: number): number {
    if (k >= table.length) {
      return renderedLength;
    }
    for (let idx = k; idx >= 0; idx--) {
      const v: number | undefined = table[idx];
      if (v !== undefined) {
        return v;
      }
    }
    return 0;
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
