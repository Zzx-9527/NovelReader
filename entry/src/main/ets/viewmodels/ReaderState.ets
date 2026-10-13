import { Book } from '../model/Book';
import { Chapter } from '../model/Chapter';
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
 * 书签切换结果。
 *
 * ⚠️ 为什么要 `ok` 和 `added` 两个字段，而不是直接返回一个 boolean：
 * "操作失败"与"成功取消了书签"都对应"当前没有书签"，
 * 用一个 boolean 表示会让页面在**失败时也提示"已取消书签"** —— 那是错的反馈。
 * 拆成两个字段，页面才能给出准确文案。
 */
export class BookmarkToggleResult {
  /** 操作本身是否成功（查库/写库没抛错） */
  ok: boolean = false;
  /** 成功时：是否处于"已加书签"状态 */
  added: boolean = false;

  static addedNow(): BookmarkToggleResult {
    const r = new BookmarkToggleResult();
    r.ok = true;
    r.added = true;
    return r;
  }

  static removed(): BookmarkToggleResult {
    const r = new BookmarkToggleResult();
    r.ok = true;
    r.added = false;
    return r;
  }

  static failed(): BookmarkToggleResult {
    return new BookmarkToggleResult();
  }
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
