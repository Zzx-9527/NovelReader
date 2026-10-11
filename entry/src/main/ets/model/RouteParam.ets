/**
 * 路由参数类型。
 *
 * 用 Navigation + NavPathStack 时，pushPathByName 的 param 用这些对象承载，
 * 页面侧用 as 断言取回。统一在这里定义，避免各页面各写一个匿名对象。
 */
export class RouteParam {
  /** 目标书籍 id（详情页 / 阅读页 / 书签页 / 搜索页） */
  bookId: number = 0;
  /** 目标章节序号（0-based，阅读页可选） */
  chapterIndex: number = -1;
  /** 章内 UTF-16 偏移（阅读页可选） */
  offset: number = 0;
  /** 搜索关键词（搜索页） */
  keyword: string = '';
  /** 来源标识，用于返回时的行为分支 */
  from: string = '';
}

/** 页面路径常量（与 resources/base/profile/main_pages.json 登记的一致） */
export class RouteName {
  static readonly INDEX_PAGE: string = 'pages/Index';
  static readonly SHELF_PAGE: string = 'pages/Index';
  static readonly READER_PAGE: string = 'pages/ReaderPage';
  static readonly BOOK_DETAIL_PAGE: string = 'pages/BookDetailPage';
  static readonly SETTINGS_PAGE: string = 'pages/SettingsPage';
  static readonly IMPORT_CONFIRM_PAGE: string = 'pages/ImportConfirmPage';
  /** 来源标识（放在 RouteParam.from 里，用于返回时的行为分支） */
  static readonly BOOK_SHELF: string = 'shelf';
  static readonly BOOK_DETAIL: string = 'detail';
}
