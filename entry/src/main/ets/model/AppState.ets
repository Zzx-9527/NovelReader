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
