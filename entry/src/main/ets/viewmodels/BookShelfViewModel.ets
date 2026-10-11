import { BusinessError } from '@kit.BasicServicesKit';
import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { ShelfState } from './ShelfState';
import { AppState, AppStateKey } from '../model/AppState';
import { BookRepository, BookSort, HashLookup } from '../data/repository/BookRepository';
import { GroupRepository } from '../data/repository/GroupRepository';
import { FilePickerSource } from '../data/source/FilePickerSource';
import { ImportService, ImportOutcome, ImportPreparation, ImportResult } from '../data/service/ImportService';
import { SettingsService } from '../data/service/SettingsService';
import { SettingsKeys } from '../common/constants/SettingsKeys';
import { Logger } from '../common/utils/Logger';
import { LogTag } from '../common/constants/AppConstants';

/**
 * 书架 ViewModel。
 *
 * 职责：只做"取数据 → 填状态"，不出现任何 UI 组件；
 * 页面只调用这里的方法，不直接碰 Repository。
 *
 * 跨页面刷新：监听 AppStorage 的 BOOKSHELF_VERSION ——
 * 阅读页改了进度、导入了新书，这个版本号会自增，书架据此自动重载。
 */
export class BookShelfViewModel {
  state: ShelfState = new ShelfState();
  private disposers: Array<() => void> = [];

  /**
   * 绑定外部状态对象（页面持有它，便于跨 Tab 保留滚动位置与选择）。
   * 必须在 init 之前调用。
   */
  bind(state: ShelfState): void {
    this.state = state;
  }

  /** 进入页面时调用：注册版本号监听并首次加载 */
  init(): void {
    this.state.gridMode = SettingsService.getInstance()
      .getBoolean(SettingsKeys.GRID_MODE, true);
    this.state.sort = BookShelfViewModel.parseSort(
      SettingsService.getInstance().getString(SettingsKeys.BOOK_SORT, BookSort.LAST_READ));

    this.observeVersion();
    this.refresh();
  }

  /** 离开页面时调用：取消监听，避免回调打到已销毁的页面 */
  dispose(): void {
    for (const dispose of this.disposers) {
      dispose();
    }
    this.disposers = [];
  }

  /**
   * 监听 AppStorage 的版本号，变化即重载。
   * 用 `AppStorage.link` 拿双向链接，set 回调里触发刷新。
   */
  private observeVersion(): void {
    try {
      AppStorage.setOrCreate<number>(AppStateKey.BOOKSHELF_VERSION,
        AppState.version(AppStateKey.BOOKSHELF_VERSION));
      let lastVersion = AppStorage.get<number>(AppStateKey.BOOKSHELF_VERSION) ?? 0;
      const timer: number = setInterval(() => {
        const currentVersion = AppStorage.get<number>(AppStateKey.BOOKSHELF_VERSION) ?? 0;
        if (currentVersion !== lastVersion) {
          lastVersion = currentVersion;
          this.refresh();
        }
      }, 300);
      this.disposers.push(() => {
        clearInterval(timer);
      });
    } catch (e) {
      // link 不可用时退化为"每次进页面手动刷新"，不影响功能
      Logger.warn(LogTag.REPO, `书架版本监听未注册: ${Logger.errText(e as Object)}`);
    }
  }

  /** 重新加载书架（分组、列表、继续阅读卡片） */
  async refresh(): Promise<void> {
    this.state.loading = true;
    try {
      const groupId: number | null = this.state.selectedGroupId < 0
        ? null
        : this.state.selectedGroupId;
      this.state.books = await BookRepository.listShelf(this.state.sort, groupId);
      this.state.groups = await GroupRepository.listAll();
      this.state.continueBook = await BookRepository.getContinueReading();
      this.state.error = '';
    } catch (e) {
      this.state.error = `加载书架失败：${Logger.errText(e as BusinessError)}`;
    } finally {
      this.state.loading = false;
    }
  }

  /** 切换分组 */
  async selectGroup(groupId: number): Promise<void> {
    this.state.selectedGroupId = groupId;
    await this.refresh();
  }

  /** 切换网格/列表，并记住选择 */
  async toggleGridMode(): Promise<void> {
    this.state.gridMode = !this.state.gridMode;
    SettingsService.getInstance().putBoolean(SettingsKeys.GRID_MODE, this.state.gridMode);
  }

  /** 切换排序，并记住选择 */
  async changeSort(sort: BookSort): Promise<void> {
    this.state.sort = sort;
    SettingsService.getInstance().putString(SettingsKeys.BOOK_SORT, sort);
    await this.refresh();
  }

  // ------------------------------------------------------------ 导入

  /** 选择文件并解析（不入库）；返回后由页面弹出编码确认 */
  async pickAndPrepare(): Promise<ImportPreparation | null> {
    this.state.importMessage = '正在选择文件…';
    this.state.importing = true;
    try {
      const uri: string = await FilePickerSource.pickTextFile();
      if (uri.length === 0) {
        this.state.importMessage = '';
        this.state.pendingImport = null;
        return null;
      }
      const preparation: ImportPreparation = await ImportService.prepare(uri, '',
        (progress) => {
          this.state.importMessage = progress.message;
        });
      this.state.importMessage = '';
      return this.handlePreparation(preparation);
    } catch (e) {
      this.state.error = `导入失败：${Logger.errText(e as BusinessError)}`;
      return null;
    } finally {
      this.state.importing = false;
    }
  }

  /**
   * 处理 prepare 的结果：
   *  - 成功 → 交给确认页
   *  - 命中在架书 → 直接提示
   *  - 命中已删除书 → 暂存，等用户选"恢复 / 作为新书导入"
   */
  private handlePreparation(preparation: ImportPreparation): ImportPreparation | null {
    const result: ImportResult = preparation.result;
    if (result.outcome === ImportOutcome.SUCCESS) {
      this.state.pendingImport = preparation;
      return preparation;
    }
    if (result.outcome === ImportOutcome.DUPLICATE_ACTIVE) {
      this.state.error = `「${result.existingBook?.title ?? '这本书'}」已经在书架里了`;
      return null;
    }
    if (result.outcome === ImportOutcome.DUPLICATE_DELETED) {
      this.state.pendingImport = preparation;
      this.state.importMessage = '检测到一本已删除的同一文件，请选择恢复或作为新书导入';
      return preparation;
    }
    if (result.outcome !== ImportOutcome.CANCELLED) {
      this.state.error = result.error;
    }
    return null;
  }

  /** 用户选择"恢复"之前命中已删除的那本书 */
  async restoreDeleted(): Promise<void> {
    const preparation = this.state.pendingImport;
    if (preparation === null) {
      return;
    }
    await ImportService.restoreDeleted(preparation);
    this.clearPendingImport();
    await this.refresh();
  }

  /** 用户选择"作为新书导入" */
  async commitPendingImport(title: string = ''): Promise<number> {
    const preparation = this.state.pendingImport;
    if (preparation === null) {
      return 0;
    }
    this.state.importing = true;
    try {
      const result: ImportResult = await ImportService.commit(preparation, title,
        (progress) => {
          this.state.importMessage = progress.message;
        });
      this.clearPendingImport();
      if (result.outcome !== ImportOutcome.SUCCESS) {
        this.state.error = result.error;
        return 0;
      }
      await this.refresh();
      return result.bookId;
    } catch (e) {
      this.state.error = `导入失败：${Logger.errText(e as BusinessError)}`;
      return 0;
    } finally {
      this.state.importing = false;
    }
  }

  /** 放弃这次导入（用户取消），清理沙箱里已复制的文件 */
  discardPendingImport(): void {
    const preparation = this.state.pendingImport;
    if (preparation !== null) {
      ImportService.discard(preparation);
    }
    this.clearPendingImport();
  }

  private clearPendingImport(): void {
    this.state.pendingImport = null;
    this.state.importMessage = '';
  }

  // ------------------------------------------------------------ 单本操作

  /** 从书架移除：软删除，沙箱文件保留以便恢复 */
  async removeBook(bookId: number): Promise<void> {
    try {
      await BookRepository.softDelete(bookId);
      await this.refresh();
    } catch (e) {
      this.state.error = `移除失败：${Logger.errText(e as BusinessError)}`;
    }
  }

  async moveToGroup(bookId: number, groupId: number | null): Promise<void> {
    try {
      await BookRepository.setGroup(bookId, groupId);
      await this.refresh();
    } catch (e) {
      this.state.error = `移动失败：${Logger.errText(e as BusinessError)}`;
    }
  }

  async createGroup(name: string): Promise<number> {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return 0;
    }
    if (await GroupRepository.existsByName(trimmed, 0)) {
      this.state.error = `分组「${trimmed}」已存在`;
      return 0;
    }
    const sortOrder: number = await GroupRepository.maxSortOrder() + 1;
    const groupId: number = await GroupRepository.insert(trimmed, sortOrder);
    await this.refresh();
    return groupId;
  }

  clearError(): void {
    this.state.error = '';
  }

  private static parseSort(value: string): BookSort {
    if (value === BookSort.ADDED) {
      return BookSort.ADDED;
    }
    if (value === BookSort.TITLE) {
      return BookSort.TITLE;
    }
    return BookSort.LAST_READ;
  }
}
