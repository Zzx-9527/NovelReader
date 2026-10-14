import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { ImportPreparation } from '../data/service/ImportService';
import { BookSort } from '../data/repository/BookRepository';

/**
 * 书架页状态对象。
 *
 * 用 `@Observed` 装饰，页面用 `@ObjectLink` 接收 ——
 * 这样内部字段（含数组）变化能直接触发刷新。
 * 注意：页面若只用 `@State` 持有 ViewModel 实例，实例内部字段变化不会重绘。
 */
@Observed
export class ShelfState {
  /** 书架书籍列表 */
  books: Book[] = [];
  /** 分组列表（含"全部"由页面自己拼） */
  groups: BookGroup[] = [];
  /** 当前选中的分组；-1 表示"全部" */
  selectedGroupId: number = -1;
  /** 继续阅读卡片 */
  continueBook: Book | null = null;

  loading: boolean = true;
  /** 非空表示出错，页面显示错误态 */
  error: string = '';

  gridMode: boolean = true;
  sort: BookSort = BookSort.LAST_READ;

  /** 待用户确认的导入（编码探测完成、尚未入库）；null 表示没有 */
  pendingImport: ImportPreparation | null = null;
  /** 导入进行中的提示文案 */
  importMessage: string = '';
  importing: boolean = false;

  /**
   * 换编码重新解析进行中。
   * 大文件解析是 CPU 密集的，必须给出可见反馈，
   * 否则用户无法区分"卡住了"和"正在处理"。
   */
  reparsing: boolean = false;
  reparseMessage: string = '';

  /**
   * 当前视图下**一本书都没有**。
   *
   * ⚠️ 这个判据**不能直接用来决定显示哪个空状态** —— 它分不清
   * "书架里真的没有书"和"当前分组里没有书"（用户实测反馈的 bug：
   * 点进空分组，页面显示"书架还是空的 + 导入 TXT"，好像书全丢了）。
   * 要区分两者必须看 `selectedGroupId`，见 `isEmptyShelf` / `isEmptyGroup`。
   */
  get isEmpty(): boolean {
    return !this.loading && !this.reparsing && this.books.length === 0;
  }

  /**
   * **书架真的空**：一本书都没有，且没有选中任何分组（"全部"视图）。
   *
   * ⚠️ 只有这一种情况才该引导"导入 TXT"：书架里一本书都没有时，
   * 用户唯一的下一步就是导入。分组筛选下即使列表为空，书架里也**有**书。
   */
  get isEmptyShelf(): boolean {
    return this.isEmpty && this.selectedGroupId < 0;
  }

  /**
   * **当前分组空**：书架里有书，只是这个分组里没有。
   *
   * ⚠️ 与 `isEmptyShelf` 互斥，两者覆盖"列表为空"的全部情形。
   * 这一种情况下正确的引导是"把书加进来"，**不是**"导入 TXT" ——
   * 让用户去导入会得到重复文件（判重会拦下来，但体验很糟），
   * 而且他会以为书架里的书不见了。
   *
   * ⚠️ 判据用 `selectedGroupId >= 0`：只要选中了真实分组，
   * 就说明这是"分组视图"，与书架里有没有书无关。
   */
  get isEmptyGroup(): boolean {
    return this.isEmpty && this.selectedGroupId >= 0;
  }
}

/**
 * 书籍详情页状态对象。
 */
@Observed
export class BookDetailState {
  book: Book | null = null;
  loading: boolean = true;
  error: string = '';
  /** 是否检测到沙箱文件丢失 */
  fileMissing: boolean = false;
  /** 受影响的书签数量（重新分章前提示用） */
  annotationCount: number = 0;
}

