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

/** 路由名称常量，禁止在页面里写裸字符串 */
export class RouteName {
  static readonly BOOK_SHELF: string = 'BookShelfPage';
  static readonly STATS: string = 'StatsPage';
  static readonly PROFILE: string = 'ProfilePage';
  static readonly IMPORT_CONFIRM: string = 'ImportConfirmPage';
  static readonly BOOK_DETAIL: string = 'BookDetailPage';
  static readonly READER: string = 'ReaderPage';
  static readonly BOOKMARK: string = 'BookmarkPage';
  static readonly SEARCH: string = 'SearchPage';
  static readonly GROUP_MANAGE: string = 'GroupManagePage';
  static readonly BACKUP: string = 'BackupPage';
  static readonly SETTINGS: string = 'SettingsPage';
}
