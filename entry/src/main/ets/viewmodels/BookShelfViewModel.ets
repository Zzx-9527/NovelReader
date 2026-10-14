import { BusinessError } from '@kit.BasicServicesKit';
import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { ShelfState } from './ShelfState';
import { BookRepository, BookSort, HashLookup } from '../data/repository/BookRepository';
import { ChapterRepository } from '../data/repository/ChapterRepository';
import { GroupRepository } from '../data/repository/GroupRepository';
import { FilePickerSource } from '../data/source/FilePickerSource';
import { ImportService, ImportOutcome, ImportPreparation, ImportResult } from '../data/service/ImportService';
import { SettingsService } from '../data/service/SettingsService';
import { SettingsKeys } from '../common/constants/SettingsKeys';
import { Logger } from '../common/utils/Logger';
import { PathUtil } from '../common/utils/PathUtil';
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

  /** 进入页面时调用：读取设置并首次加载 */
  init(): void {
    this.state.gridMode = SettingsService.getInstance()
      .getBoolean(SettingsKeys.GRID_MODE, true);
    this.state.sort = BookShelfViewModel.parseSort(
      SettingsService.getInstance().getString(SettingsKeys.BOOK_SORT, BookSort.LAST_READ));
    this.reloadData();
  }

  /**
   * 只取数据、不改设置。
   *
   * 与 refresh() 分开的原因：init() 需要先读设置（要求 SettingsService 已就绪），
   * 而"切回书架时重载"只该查数据，不该再碰设置。
   */
  async reloadData(): Promise<void> {
    this.state.loading = true;
    try {
      const groupId: number | null = this.state.selectedGroupId < 0
        ? null
        : this.state.selectedGroupId;
      // 整体替换 books 数组而不是原地改：确保 ArkUI 一定能观察到变化
      const books: Book[] = await BookRepository.listShelf(this.state.sort, groupId);
      this.state.books = books;
      const groups: BookGroup[] = await GroupRepository.listAll();
      this.state.groups = groups;
      const continueBook: Book | null = await BookRepository.getContinueReading();
      this.state.continueBook = continueBook;
      this.state.error = '';
    } catch (e) {
      this.state.error = `加载书架失败：${Logger.errText(e as BusinessError)}`;
    } finally {
      this.state.loading = false;
    }
  }

  /** 重新加载（含分组与继续阅读卡片） */
  async refresh(): Promise<void> {
    await this.reloadData();
  }

  /** 离开页面时调用：取消监听，避免回调打到已销毁的页面 */
  dispose(): void {
    for (const dispose of this.disposers) {
      dispose();
    }
    this.disposers = [];
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
   *  - 成功 → 交给确认流程
   *  - 命中在架书 → 直接提示"已在书架"
   *  - 其余（取消/失败）→ 置错误文案
   *
   * 注意：命中"已删除的同一文件"不再挂起等用户选择 ——
   * ImportService 会直接清掉那条旧记录并正常导入（否则用户点导入会没反应）。
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
    if (result.outcome !== ImportOutcome.CANCELLED) {
      this.state.error = result.error;
    }
    return null;
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
      if (result.outcome !== ImportOutcome.SUCCESS) {
        /**
         * ⚠️ **失败时不能清空 `pendingImport`**（这里曾经无条件清空）。
         *
         * 清掉的后果有两个，都很糟：
         *  1. 确认页拿不到待确认数据，用户**无法重试**（只能回书架重新选文件）；
         *  2. 那次 `prepare()` 已经复制进沙箱的文件**再也没人清理** ——
         *     `discardPendingImport()` 依赖 `pendingImport` 非空，
         *     清空后它什么都不做，孤儿文件永久留下。
         * 保留它，用户可以直接再点"导入"，取消时也仍能正常清理。
         */
        this.state.error = result.error;
        return 0;
      }
      // 只有真正入库成功才消费掉这份待确认数据
      this.clearPendingImport();
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

  /**
   * 用户在确认页换了编码：**重新分章**并刷新预览（不入库）。
   *
   * ⚠️ `ImportService.parseInto` 是**同步且 CPU 密集**的（整文件解码 + 行级正则）。
   * 这里用 async 包一层只是为了统一错误处理，**不能**因此以为 UI 不会卡 ——
   * 大文件下这一步仍会阻塞若干秒。彻底的解法是 taskpool（见设计文档风险表），
   * 当前由确认页的"正在重新解析…"文案告知用户，避免被误认为卡死。
   *
   * ⚠️ 重新分章会**覆盖** `preparation.chapters`，所以调用方必须在成功后
   * 重新读取预览（本方法不返回章节，由页面从 state 取）。
   *
   * @returns 是否成功（失败原因写进 `state.error`）
   */
  async reparsePendingImport(encoding: string): Promise<boolean> {
    const preparation = this.state.pendingImport;
    if (preparation === null) {
      return false;
    }
    this.state.importing = true;
    try {
      const result: ImportResult = ImportService.parseInto(preparation, encoding);
      if (result.outcome !== ImportOutcome.SUCCESS) {
        this.state.error = result.error;
        return false;
      }
      this.state.error = '';
      return true;
    } catch (e) {
      this.state.error = `重新解析失败：${Logger.errText(e as BusinessError)}`;
      return false;
    } finally {
      this.state.importing = false;
    }
  }

  /**
   * 确认页要显示的**前几个章节标题**。
   *
   * ⚠️ 只返回标题字符串，**不把 `preparation` 整个交给 UI**：
   * 1000+ 章的数组一旦经 `@Prop` 传进组件就会被**深拷贝**，
   * 每次重绘都复制上千个对象。只传展示需要的那几个字符串，代价可忽略。
   *
   * @param limit 最多取几条（默认 8：够看出分章质量，又不会把页面撑长）
   */
  pendingImportPreview(limit: number = 8): string[] {
    const preparation = this.state.pendingImport;
    if (preparation === null) {
      return [];
    }
    const titles: string[] = [];
    const count: number = Math.min(limit, preparation.chapters.length);
    for (let i = 0; i < count; i++) {
      const chapter = preparation.chapters[i];
      titles.push(chapter.title.length > 0 ? chapter.title : `第 ${i + 1} 章`);
    }
    return titles;
  }

  /**
   * 确认页的默认书名（取自文件名，去扩展名）。
   *
   * 与 `ImportService.commit` 在 `bookTitle` 为空时的兜底**同源**，
   * 但这里显式取出来放进输入框，用户能看见并直接改 —— 而不是"看不见却生效"。
   */
  pendingImportDefaultTitle(): string {
    const preparation = this.state.pendingImport;
    if (preparation === null) {
      return '';
    }
    return PathUtil.fileNameWithoutExt(preparation.uri);
  }

  /** 当前待确认导入的编码（确认页高亮用） */
  pendingImportEncoding(): string {
    const preparation = this.state.pendingImport;
    return preparation === null ? '' : preparation.encoding;
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

  /**
   * 换编码重新解析。
   *
   * 场景：自动探测的编码不对（正文乱码）时，用户手动指定编码后重建章节。
   *
   * ⚠️ 会因外键 CASCADE 删除该书全部书签/笔记，所以先统计数量并让页面提示。
   *
   * @returns 是否成功
   */
  async reparseWithEncoding(bookId: number, encoding: string): Promise<boolean> {
    this.state.reparsing = true;
    this.state.reparseMessage = `正在按 ${encoding} 重新解析，大文件需要几秒…`;
    try {
      const impacted: number = await ChapterRepository.countAnnotationsImpacted(bookId);
      if (impacted > 0) {
        // 只记录，不静默删：调用方（页面）已在标题里提示过数量
        Logger.warn(LogTag.IMPORT,
          `换编码重新解析将级联删除 ${impacted} 条书签/笔记（bookId=${bookId}）`);
      }
      const result: ImportResult = await ImportService.reparse(bookId, encoding);
      await this.reloadData();
      if (result.outcome !== ImportOutcome.SUCCESS) {
        this.state.error = result.error;
        return false;
      }
      return true;
    } catch (e) {
      this.state.error = `重新解析失败：${Logger.errText(e as BusinessError)}`;
      return false;
    } finally {
      this.state.reparsing = false;
      this.state.reparseMessage = '';
    }
  }

  /** 读取某本书当前记录的编码，供"换编码"对话框预选 */
  async currentEncoding(bookId: number): Promise<string> {
    const book: Book | null = await BookRepository.getById(bookId);
    return book === null ? '' : book.encoding;
  }

  /** 某本书会被"重新解析"影响的标注数量，供提示用 */
  async annotationsImpacted(bookId: number): Promise<number> {
    return ChapterRepository.countAnnotationsImpacted(bookId);
  }

  /**
   * 新建分组。
   *
   * @returns 新分组 id；0 表示失败（名称为空或重名，原因已写进 `state.error`）
   */
  async createGroup(name: string): Promise<number> {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      // 空名字不写 error：调用方（输入弹窗）自己会拦，写进去反而会盖掉别的提示
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

  /**
   * 重命名分组。
   *
   * ⚠️ `existsByName` 要传 `excludeId`：不排除自己的话，
   * "把 A 改名为 A"（用户只是想确认一下、或改了大小写又改回来）会被判成重名。
   *
   * @returns 是否成功
   */
  async renameGroup(groupId: number, name: string): Promise<boolean> {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return false;
    }
    try {
      if (await GroupRepository.existsByName(trimmed, groupId)) {
        this.state.error = `分组「${trimmed}」已存在`;
        return false;
      }
      await GroupRepository.rename(groupId, trimmed);
      await this.refresh();
      return true;
    } catch (e) {
      this.state.error = `重命名失败：${Logger.errText(e as BusinessError)}`;
      return false;
    }
  }

  /**
   * 删除分组。
   *
   * ⚠️ **只删分组、不删书**：仓储内部先把成员 `group_id` 置空再软删分组
   * （软删除不触发外键 `ON DELETE SET NULL`，不解绑的话这些书会因为
   * 指向已删分组而从书架消失）。返回值是解绑的书籍数，供页面提示用。
   *
   * @returns 被移出该分组的书籍数量；-1 表示失败
   */
  async deleteGroup(groupId: number): Promise<number> {
    try {
      const moved: number = await GroupRepository.softDeleteWithMembers(groupId);
      /**
       * ⚠️ 删掉的若是**当前选中**的分组，必须把选择退回"全部"。
       * 否则 `selectedGroupId` 指向一个已不存在的分组，书架会显示成空列表
       * ——用户看到的是"删了个分组，我的书全没了"。
       */
      if (this.state.selectedGroupId === groupId) {
        this.state.selectedGroupId = -1;
      }
      await this.refresh();
      return moved;
    } catch (e) {
      this.state.error = `删除分组失败：${Logger.errText(e as BusinessError)}`;
      return -1;
    }
  }

  /** 某分组下的书籍数量（删除前提示用） */
  async countInGroup(groupId: number): Promise<number> {
    return BookRepository.countInGroup(groupId);
  }

  clearError(): void {
    this.state.error = '';
  }
}
