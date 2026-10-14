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
  /**
   * 目标分组 id（"选择书籍加入分组"页用）。
   *
   * ⚠️ 用 `-1` 表示"未分组"，**不要用 0** —— 0 是数据库自增主键的保留起点，
   * 拿它当"无分组"的哨兵，将来某天真出现 id=0 就会撞车。
   * 与 `chapterIndex` 用 -1 表示"未指定"是同一套约定。
   */
  groupId: number = -1;
  /** 来源标识，用于返回时的行为分支 */
  from: string = '';
}

/** 页面路径常量（与 resources/base/profile/main_pages.json 登记的一致） */
export class RouteName {
  /** 首个页面：`EntryAbility.onWindowStageCreate` 加载它，预热完 replaceUrl 到书架 */
  static readonly SPLASH_PAGE: string = 'pages/SplashPage';
  static readonly INDEX_PAGE: string = 'pages/Index';
  static readonly SHELF_PAGE: string = 'pages/Index';
  static readonly READER_PAGE: string = 'pages/ReaderPage';
  /**
   * 阅读页的**目录页**（目录 + 书签两个 Tab）。
   *
   * ⚠️ 它与阅读页是两个独立页面，用 `pushUrl` 进入。
   * 选章结果**不走路由回传**，而是通过 `ReaderJumpRegistry` 交接 ——
   * 原因见该文件的说明（页面栈下标脆弱、`back` 不承诺传参）。
   */
  static readonly READER_CATALOG_PAGE: string = 'pages/ReaderCatalogPage';
  static readonly BOOK_DETAIL_PAGE: string = 'pages/BookDetailPage';
  static readonly SETTINGS_PAGE: string = 'pages/SettingsPage';
  static readonly IMPORT_CONFIRM_PAGE: string = 'pages/ImportConfirmPage';
  /**
   * 「把已导入的书加入分组」页。
   *
   * ⚠️ 它是"分组 → 挑书"这条链路的落地页：分组本身只是个标签，
   * 真正要做的事是**从已导入的书里选**。没有这一页，分组功能就只有
   * "建/改名/删"，永远装不进任何一本书（本项目实测踩过这个缺口）。
   */
  static readonly GROUP_PICKER_PAGE: string = 'pages/GroupPickerPage';
  /** 来源标识（放在 RouteParam.from 里，用于返回时的行为分支） */
  static readonly BOOK_SHELF: string = 'shelf';
  static readonly BOOK_DETAIL: string = 'detail';
}
