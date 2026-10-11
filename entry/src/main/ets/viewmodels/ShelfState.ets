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

  get isEmpty(): boolean {
    return !this.loading && this.books.length === 0;
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

/**
 * 导入确认页状态对象。
 */
@Observed
export class ImportState {
  preparation: ImportPreparation | null = null;
  /** 用户当前选中的编码 */
  encoding: string = '';
  /** 编码候选，供用户切换 */
  encodingOptions: string[] = [];
  /** 解析预览（前几章标题） */
  previewTitles: string[] = [];
  chapterCount: number = 0;
  wordCount: number = 0;
  /** 编码置信度低时提示用户手动确认 */
  lowConfidence: boolean = false;
  fallback: boolean = false;
  parsing: boolean = false;
  error: string = '';
}
