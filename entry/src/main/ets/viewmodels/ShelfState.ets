import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { ShelfEntry } from '../model/ShelfEntry';
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
  /**
   * 书架首页的**混排列表**：分组与书籍按**同一套排序**交错排列。
   *
   * ⚠️ 这是首页**唯一**的渲染数据源（页面只遍历它）。
   *
   * 为什么不是"分组一个数组、书一个数组"（早期实现）：
   * 用户明确要求"分组就相当于一本书"，所以刚读完的书必须能排在分组**前面**。
   * 而两个独立数组无论各自怎么排，渲染出来永远是"分组全在前、书全在后"——
   * 做不到交错。判据：**要交错渲染，就必须先交错成一条数组**。
   *
   * ⚠️ `books` / `groups` 仍各自保留：它们是**原始数据**，
   * 混排结果由它们派生（换排序时不必再查库）。
   */
  entries: ShelfEntry[] = [];
  /**
   * 未分组的书（首页列表的来源之一）。
   *
   * ⚠️ 不是"全部书"。分组是**文件夹**语义（点进去才看到组内的书），
   * 所以已归组的书只应出现在它所属的分组里，不在首页再出现一次 ——
   * 否则同一本书两处都能看到，用户会疑惑"到底在哪"，
   * 而且首页会随着归组越来越多而越堆越长（用户明确要求如此）。
   */
  books: Book[] = [];
  /**
   * 分组列表（**带组内书籍数量与可排序时间**）。
   *
   * ⚠️ 首页把分组渲染成"一本书"（封面 + 名称 + 数量），
   * 所以数量必须在**同一次查询**里取回来（`listAllWithCount`），
   * 不能渲染时逐个再查 —— 那是 N+1 次 IO。
   *
   * ⚠️ 分组还必须带 `lastReadAt` / `addedAt`，否则无法参与混排排序。
   */
  groups: BookGroup[] = [];
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
   * 首页**完全为空**：既没有分组，也没有未分组的书。
   *
   * ⚠️ 只有这种情况才该引导"导入 TXT" —— 此时用户唯一的下一步就是导入。
   * 注意判据要**同时**看 groups：只有分组、没有散书时不该显示"书架还是空的"，
   * 否则用户会以为分组也没了（分组恰恰是他自己建的）。
   *
   * ⚠️ 它与 `build()` 里的 `else` 分支互补：不为空就渲染列表，
   * 两者覆盖全部情形，不需要额外的"有内容"判据。
   */
  get isEmptyShelf(): boolean {
    return !this.loading && !this.reparsing
      && this.books.length === 0 && this.groups.length === 0;
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

