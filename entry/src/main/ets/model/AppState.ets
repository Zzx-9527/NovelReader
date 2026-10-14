import { DbConstants } from '../common/constants/DbConstants';

/**
 * 全局应用状态：AppStorage 的 key 与类型定义。
 *
 * 跨页面刷新方案（设计文档 8.1）：Repository / Service 写操作成功后
 * 自增对应的版本号，ViewModel 监听版本号变化后重新加载。
 * 这样阅读页改了进度、导入完成了新书，书架都会自动刷新，
 * 页面之间不需要互相引用，也不需要事件总线。
 */
export class AppStateKey {
  /** 书架数据版本：书籍增删改、进度变化时自增 */
  static readonly BOOKSHELF_VERSION: string = 'bookshelfVersion';
  /** 分组数据版本 */
  static readonly GROUP_VERSION: string = 'groupVersion';
  /** 统计版本：阅读时长变化时自增 */
  static readonly STATS_VERSION: string = 'statsVersion';
  /** 当前正在阅读的书籍 id（供服务卡片"继续阅读"读取） */
  static readonly CURRENT_BOOK_ID: string = 'currentBookId';
  /** 全局阅读设置是否已加载完成 */
  static readonly SETTINGS_READY: string = 'settingsReady';
  /**
   * **应用级**主题当前是否为夜间（boolean）。
   *
   * ⚠️ 与阅读页的 `ReaderTheme` 无关：本项是"整个 app 是否深色"，
   * 由 `ThemeApplier` 在施加主题后写入，页面用 `@StorageProp` 订阅高亮态。
   * 为什么放 `AppStorage`：判断"系统现在是不是深色"需要 `Context.config`，
   * 而页面拿不到 Context —— 与 `safeAreaTop` 同一套共享范式。
   */
  static readonly APP_DARK_MODE: string = 'appDarkMode';
  /**
   * 顶部安全区（状态栏）高度，单位 **vp**。
   *
   * 为什么放进 AppStorage：开启沉浸式全屏后，窗口内容会盖住状态栏/手势条，
   * 各页面必须**自己**让出这段高度。而安全区高度只有 `EntryAbility`
   * 拿得到 `Window` 才能测，页面拿不到 —— 于是测一次、全局共享。
   * 页面用 `@StorageProp` 订阅，值到位后自动重排，不需要自己处理异步时序。
   */
  static readonly SAFE_AREA_TOP: string = 'safeAreaTop';
  /** 底部安全区（手势条）高度，单位 **vp** */
  static readonly SAFE_AREA_BOTTOM: string = 'safeAreaBottom';
}

/** 版本号自增（写操作完成后调用） */
export class AppState {
  static bumpBookshelf(): void {
    AppState.bump(AppStateKey.BOOKSHELF_VERSION);
  }

  static bumpGroup(): void {
    AppState.bump(AppStateKey.GROUP_VERSION);
  }

  static bumpStats(): void {
    AppState.bump(AppStateKey.STATS_VERSION);
  }

  static bump(key: string): void {
    const current: number = AppStorage.get<number>(key) ?? 0;
    AppStorage.setOrCreate<number>(key, current + 1);
  }

  /** 读取版本号，未初始化时返回 0 */
  static version(key: string): number {
    return AppStorage.get<number>(key) ?? 0;
  }

  static setCurrentBook(bookId: number): void {
    AppStorage.setOrCreate<number>(AppStateKey.CURRENT_BOOK_ID, bookId);
  }

  static currentBook(): number {
    return AppStorage.get<number>(AppStateKey.CURRENT_BOOK_ID) ?? DbConstants.NO_PROGRESS;
  }
}
