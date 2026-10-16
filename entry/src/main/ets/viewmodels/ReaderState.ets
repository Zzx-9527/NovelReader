import { Book } from '../model/Book';
import { Chapter } from '../model/Chapter';
import { Annotation } from '../model/Annotation';
import { ReaderSettings } from '../model/ReaderSettings';
import { ReadingPosition } from '../model/ReadingPosition';

/**
 * 阅读页状态对象（@Observed + 页面 @ObjectLink）。
 */
@Observed
export class ReaderState {
  book: Book | null = null;
  settings: ReaderSettings = new ReaderSettings();

  /** 目录（用于上一章/下一章与进度显示） */
  chapters: Chapter[] = [];

  chapterIndex: number = -1;
  chapterTitle: string = '';

  /** 当前章完整正文 */
  private fullText: string = '';
  /** 分页断点（scroll 模式下为空） */
  breaks: number[] = [];
  pageIndex: number = 0;
  pageCount: number = 1;

  /** 实际渲染的文本：scroll 模式为整章，page 模式为当前页 */
  renderedText: string = '';
  /**
   * 滚动模式的**连续窗口**：相邻章节的正文块列表（可含上一章 / 当前章 / 下一章）。
   *
   * ⚠️ 这是滚动模式的渲染数据源（页面 `ForEach` 遍历它），
   * 与 `renderedText`（**当前章**的渲染文本）并存：
   * 进度、书签、划线、选中换算的**坐标系锚在当前章**（`fullText`/`renderedText`），
   * 窗口只是把相邻章的内容**铺在同一股滚动流里** ——
   * 二者职责不同，不能合并：合并意味着换章时整个坐标系要搬家，
   * 而选中/书签的偏移换算全都要跟着改。
   *
   * ⚠️ 整个数组**一次性替换**（不是原地改元素），确保 @Observed 观察得到。
   */
  scrollSections: ScrollSection[] = [];
  /**
   * 滚动窗口的**代数**：每次窗口平移（换当前章）+1。
   *
   * ⚠️ 页面 ForEach 的键生成要用它：仅用 chapterIndex 作键时，
   * "窗口滑回来又看到同一章"会命中旧组件实例、显示**旧排版**的内容
   * （ArkUI 复用实例、不重建子树）。代数一变，键就变，强制重建。
   */
  scrollWindowRev: number = 0;

  /**
   * 当前章的**划线**（只含 `ANNOTATION_HIGHLIGHT`，不含书签与笔记）。
   *
   * ⚠️ 为什么正文里只画划线：书签是"一个位置"而不是"一段范围"，
   * 没有区间可上底色；笔记的正文是用户写的备注、在段落里没有落脚处。
   * 两者都在目录页的「书签 / 笔记」Tab 里看。给它们上底色只会让正文变花，
   * 用户还分不清这一段到底是划线还是笔记。
   *
   * ⚠️ 必须在**每次换章、每次重新分页**时跟着刷新：
   * `buildTextRuns` 依赖它算出本页的高亮区间，留旧章的划线
   * 会让新章正文出现不相干的高亮（而且看起来像数据错乱）。
   */
  highlights: Annotation[] = [];
  /**
   * 本页是否从**段落中间**开始（即上一页把这一段切开了）。
   *
   * ⚠️ 它决定首行缩进怎么画：
   * 段落的第一行在上一页已经缩进过了，本页开头那一行是**续行**，
   * 再缩进就会让读者误以为"这里新起了一段"。
   *
   * `Text.textIndent` 是按 `\n` 对**每一段第一行**生效的，
   * 没法只对"本页第一行"关闭 —— 所以续排时整页关掉缩进，
   * 再由 `renderAt` 往**本页内真正的段首行**手工补缩进字符（见 `renderedText` 的构造）。
   */
  pageStartsMidParagraph: boolean = false;

  /** 章内 UTF-16 偏移（= 当前页起始偏移） */
  offset: number = 0;
  /** 跨章节的全局进度 0~1 */
  percent: number = 0;

  /** 顶栏/底栏是否显示，单击中间切换 */
  menuVisible: boolean = false;
  /**
   * 阅读设置面板是否显示。
   *
   * 与 `menuVisible` 分开而不是复用：设置面板弹出时，底栏里那个"设置"
   * 按钮最好仍可见（用户可能想连调几项），两者显隐规则并不一致。
   * 面板盖住底栏这件事由 `ReaderPage` 的 Stack 层级决定，状态各管各的。
   */
  settingsVisible: boolean = false;

  /**
   * 加书签弹窗是否显示。
   *
   * 与 `settingsVisible` 同理各管各的：书签弹窗由长按选中触发，
   * 与菜单/设置面板的显隐互不相干。
   */
  bookmarkVisible: boolean = false;

  loading: boolean = true;
  error: string = '';
  /** 分页未命中缓存时提示正在重算 */
  repaginating: boolean = false;

  get hasPrev(): boolean {
    return this.chapterIndex > 0;
  }

  get hasNext(): boolean {
    return this.chapters.length > 0 && this.chapterIndex < this.chapters.length - 1;
  }

  get progressText(): string {
    const percent: number = this.percent < 0 ? 0 : (this.percent > 1 ? 1 : this.percent);
    return `${(percent * 100).toFixed(1)}%`;
  }

  get pageText(): string {
    if (this.settings.pageMode === 'scroll') {
      return '';
    }
    return `${this.pageIndex + 1}/${this.pageCount}`;
  }

  /** 供 ViewModel 更新正文（fullText 是私有字段，需要显式方法） */
  setFullText(text: string): void {
    this.fullText = text;
  }

  getFullText(): string {
    return this.fullText;
  }
}

/**
 * 书签保存结果。
 *
 * ⚠️ 为什么不是简单返回 `boolean`：这里有两个**都算成功**但用户需要区分的结局
 * —— "新建了一条"与"覆盖了同位置已有的那条"。用 boolean 只能表达成功/失败，
 * 弹窗就没法给出准确反馈（用户会疑惑"我刚才是加了一条还是改了一条"）。
 *
 * ⚠️ 与"失败"必须分开：失败若和某个成功态共用返回值，
 * 页面就会在失败时提示成功（本项目踩过，见设计文档 pitfall 63）。
 */
export class BookmarkSaveResult {
  /** 是否保存成功 */
  ok: boolean = false;
  /** 成功时：true = 覆盖了同位置旧书签；false = 新建 */
  updated: boolean = false;

  static saved(updated: boolean): BookmarkSaveResult {
    const r = new BookmarkSaveResult();
    r.ok = true;
    r.updated = updated;
    return r;
  }

  static failed(): BookmarkSaveResult {
    return new BookmarkSaveResult();
  }
}

/**
 * 书签编辑草稿（长按选中 → 弹窗里要展示/编辑的三块内容）。
 *
 * ⚠️ 为什么不直接传 `Annotation`：弹窗里"章节名"是**展示用**的（由
 * `ReaderViewModel` 按当前章查出来），并不是 `Annotation` 的字段
 * （`Annotation` 只存 `chapterIndex`）。混用会让人以为数据库里有这一列。
 */
export class BookmarkDraft {
  /** 第几章：直接给可读文案，弹窗不做二次拼装 */
  chapterLabel: string = '';
  /** 选中的正文内容（原文，未装饰） */
  selectedText: string = '';
  /** 用户填的备注，可为空 */
  note: string = '';
  /** 章内 UTF-16 偏移（**原文**坐标） */
  startOffset: number = 0;
  /** 选文结束偏移；未选中具体区间时为 -1 */
  endOffset: number = -1;

  /** 是否已有同位置书签（决定弹窗是"新增"还是"覆盖"语气） */
  existing: boolean = false;
}

/**
 * 阅读位置恢复结果（给页面弹提示用）。
 */
export class ReaderRestoreInfo {
  restored: boolean = false;
  chapterIndex: number = 0;
  pageIndex: number = 0;
  cacheHit: boolean = false;
  percent: number = 0;

  static fromPosition(pos: ReadingPosition, pageIndex: number, cacheHit: boolean): ReaderRestoreInfo {
    const info = new ReaderRestoreInfo();
    info.restored = pos.chapterIndex >= 0;
    info.chapterIndex = pos.chapterIndex < 0 ? 0 : pos.chapterIndex;
    info.pageIndex = pageIndex;
    info.cacheHit = cacheHit;
    info.percent = pos.percent;
    return info;
  }
}

/**
 * 滚动模式连续窗口里的**一个章节块**（标题 + 已装饰正文）。
 *
 * ⚠️ `decoratedText` 是**渲染副本**（经 `indentParagraphHeads` 装饰），
 * 与 `ReaderState.renderedText` 同一性质 —— 偏移换算一律走原文，
 * 本类只负责"画什么"，不参与任何坐标计算。
 *
 * ⚠️ 划线**只对当前章生效**（`isCurrent` 为 true 的块由页面按
 * `state.highlights` 分段渲染）；相邻章的划线不取 ——
 * 它们在视口里只是"将读未读的预览"，为几十行预览多做一次 DB 查询
 * 与一整套双游标对齐，代价大于收益。滑过去变成当前章时自然补上。
 */
export class ScrollSection {
  /** 章节序号（全书 0-based） */
  chapterIndex: number = -1;
  /** 章节标题（目录同名；渲染成块头） */
  title: string = '';
  /** 已装饰的整章正文（渲染副本，勿回填原文） */
  decoratedText: string = '';
  /** 是否当前章（决定划线渲染与底栏章节名的口径） */
  isCurrent: boolean = false;
}
