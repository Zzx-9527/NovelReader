import { BusinessError } from '@kit.BasicServicesKit';
import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { ShelfEntry } from '../model/ShelfEntry';
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
import { AppConstants, LogTag } from '../common/constants/AppConstants';

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
   *
   * ⚠️ 首页取的是**未分组**的书（`listUngrouped`），不是全部书：
   * 分组现在是"文件夹"语义，已归组的书只出现在组内，不在首页重复出现
   * （用户明确要求）。分组用 `listAllWithCount` 一次带回数量。
   */
  async reloadData(): Promise<void> {
    this.state.loading = true;
    try {
      // 整体替换数组而不是原地改：确保 ArkUI 一定能观察到变化
      const books: Book[] = await BookRepository.listUngrouped(this.state.sort);
      this.state.books = books;
      // 带 bookCount：首页把分组当"一本书"显示，要标出组内数量
      const groups: BookGroup[] = await GroupRepository.listAllWithCount();
      await this.attachCoverBooks(groups);
      this.state.groups = groups;
      // 分组与书**混排**成一条数组（用户要求：分组就相当于一本书）
      this.state.entries = BookShelfViewModel.buildEntries(groups, books, this.state.sort);
      const continueBook: Book | null = await BookRepository.getContinueReading();
      this.state.continueBook = continueBook;
      this.state.error = '';
    } catch (e) {
      this.state.error = `加载书架失败：${Logger.errText(e as BusinessError)}`;
    } finally {
      this.state.loading = false;
    }
  }

  /**
   * 把分组与未分组的书**混排**成一条有序数组。
   *
   * ⚠️ 这是"分组就相当于一本书"的落地实现（用户明确要求）：
   * 刚读完的书必须能排在分组**前面**，而两个独立数组做不到交错，
   * 所以必须在这里合并、排序、输出一条数组。
   *
   * ⚠️ 排序键**必须与 SQL 的 `ORDER BY` 语义一致**，否则会出现
   * "书与书之间的相对顺序"和"分组插进去的位置"两套逻辑打架。
   * 三个排序键的对应关系：
   *  - `LAST_READ`：书用 `lastReadAt`，分组用组内 `MAX(lastReadAt)`；
   *    **从未读过的排在最后**（与 SQL 的 `last_read_at IS NULL` 一致）——
   *    不能把 null 当 0，那会让"没读过"排到"很久以前读过"的前面。
   *  - `ADDED`：书用 `addedAt`，分组用组内 `MAX(addedAt)`
   *    （空分组退回分组创建时间，见 `GroupRepository`）。
   *  - `TITLE`：书用 `title`，分组用 `name`。
   *
   * ⚠️ 用**显式比较函数**而不是 `Array.sort()` 的默认行为：
   * 默认排序会把元素转成字符串比较，中文与数字都会排错。
   *
   * ⚠️ 同键时的**兜底次序**必须确定（否则每次刷新的顺序可能不同）：
   * 这里用"分组在后、id 升序"，保证结果可复现。
   */
  private static buildEntries(groups: BookGroup[], books: Book[],
    sort: BookSort): ShelfEntry[] {
    const entries: ShelfEntry[] = [];
    for (const group of groups) {
      const entry = new ShelfEntry();
      entry.isGroup = true;
      entry.group = group;
      entries.push(entry);
    }
    for (const book of books) {
      const entry = new ShelfEntry();
      entry.isGroup = false;
      entry.book = book;
      entries.push(entry);
    }

    entries.sort((a: ShelfEntry, b: ShelfEntry): number => {
      if (sort === BookSort.TITLE) {
        const an: string = a.isGroup ? a.group.name : a.book.title;
        const bn: string = b.isGroup ? b.group.name : b.book.title;
        /**
         * ⚠️ 用简单的 `<` / `>` 比较，**不用 `localeCompare`**。
         *
         * `localeCompare` 是**本地化**排序（中文按拼音），而书架的
         * `ORDER BY title ASC` 在 SQLite 里是**二进制**比较 ——
         * 两者对中文的次序完全不同。混排时若分组用拼音序、书用二进制序，
         * 结果会看起来"忽 A 忽 B"，很难解释。
         *
         * 判据：**混排的所有元素必须用同一套比较规则**，
         * 且那套规则要与原有的 SQL 排序一致（否则改动前后书的相对次序会变）。
         */
        if (an < bn) {
          return -1;
        }
        if (an > bn) {
          return 1;
        }
        return BookShelfViewModel.tieBreak(a, b);
      }

      if (sort === BookSort.ADDED) {
        const at: number = a.isGroup ? a.group.addedAt : a.book.addedAt;
        const bt: number = b.isGroup ? b.group.addedAt : b.book.addedAt;
        if (at !== bt) {
          // 导入时间：新的在前（与 SQL 的 added_at DESC 一致）
          return bt - at;
        }
        return BookShelfViewModel.tieBreak(a, b);
      }

      // LAST_READ：null 表示"从未读过"，一律排到最后
      const ar: number | null = a.isGroup ? a.group.lastReadAt : a.book.lastReadAt;
      const br: number | null = b.isGroup ? b.group.lastReadAt : b.book.lastReadAt;
      if (ar === null && br === null) {
        return BookShelfViewModel.tieBreak(a, b);
      }
      if (ar === null) {
        return 1;
      }
      if (br === null) {
        return -1;
      }
      if (ar !== br) {
        // 最近阅读：越新越靠前
        return br - ar;
      }
      return BookShelfViewModel.tieBreak(a, b);
    });

    return entries;
  }

  /**
   * 排序键相同时的**确定性兜底**。
   *
   * ⚠️ 必须有：比较函数返回 0 时，`sort` 的稳定性在不同引擎上不保证，
   * 表现是"每次刷新顺序都可能变一下"。用"分组在后、id 升序"固定下来，
   * 结果可复现（也让问题容易定位）。
   *
   * ⚠️ 分组排在后是刻意的：分组是"容器"，把容器放在内容前面会挡视线；
   * 而"刚读完的书"正是用户最想第一眼看到的（用户明确反馈过这一点）。
   */
  private static tieBreak(a: ShelfEntry, b: ShelfEntry): number {
    if (a.isGroup !== b.isGroup) {
      return a.isGroup ? 1 : -1;
    }
    const aid: number = a.isGroup ? a.group.id : a.book.id;
    const bid: number = b.isGroup ? b.group.id : b.book.id;
    return aid - bid;
  }

  /**
   * 给每个分组填上"组内前几本书"（`coverBooks`），供封面渲染。
   *
   * ⚠️ 一次查全部已归组的书、在内存里按组切前 N 本，
   * **不要**对每个分组各查一次 —— 那是 N+1 次 IO，而首页每次刷新都要跑。
   *
   * ⚠️ 切分依据是"`listGrouped` 已按 `group_id` 排好序"：
   * 同一个分组的书在结果里是**连续**的一段，所以顺序扫一遍、
   * 每遇到新 groupId 就开一段即可，不需要哈希表或二次排序。
   * 一旦 `listGrouped` 的 ORDER BY 变了，这里的假设就会失效 ——
   * 两处是**耦合**的，改那边必须回来看这里。
   */
  private async attachCoverBooks(groups: BookGroup[]): Promise<void> {
    if (groups.length === 0) {
      return;
    }
    const slots: number = AppConstants.GROUP_COVER_SLOTS;
    const grouped: Book[] = await BookRepository.listGrouped(this.state.sort);
    for (const book of grouped) {
      const gid: number | null = book.groupId;
      if (gid === null) {
        continue;
      }
      for (const group of groups) {
        if (group.id !== gid) {
          continue;
        }
        // 只收前 slots 本：填满封面格子后就不再变化（用户明确要求）
        if (group.coverBooks.length < slots) {
          group.coverBooks.push(book);
        }
        break;
      }
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

  /**
   * 把一本书移入某个分组（`null` = 移出分组，即"未分组"）。
   *
   * ⚠️ 这是"分组"功能的**核心动作**：分组本身只是个标签，
   * 只有能把已导入的书放进去，这个功能才有意义。
   * 早期只做了"建/改名/删分组"，这个方法写好了却**从未被调用** ——
   * 结果是分组永远是空的（本项目实测踩过）。
   */
  async moveToGroup(bookId: number, groupId: number | null): Promise<void> {
    try {
      await BookRepository.setGroup(bookId, groupId);
      await this.refresh();
    } catch (e) {
      this.state.error = `移动失败：${Logger.errText(e as BusinessError)}`;
    }
  }

  /**
   * **批量**把多本书加入分组（选择页点"完成"时调用）。
   *
   * ⚠️ 逐本 await 而不是并发 `Promise.all`：
   *  - 都是同一个 RdbStore 上的写操作，并发提交反而容易撞事务；
   *  - 顺序执行在几十~几百本的量级下完全够快（每本一条 UPDATE）。
   *
   * ⚠️ 失败要**计数并如实返回**，不能吞掉：用户勾了 20 本、实际只成功 18 本
   * 却提示"已完成"，他会以为全部放好了。返回成功数由调用方决定怎么提示。
   *
   * @returns 实际成功的本数
   */
  async moveManyToGroup(bookIds: number[], groupId: number | null): Promise<number> {
    let succeeded: number = 0;
    try {
      for (const bookId of bookIds) {
        await BookRepository.setGroup(bookId, groupId);
        succeeded++;
      }
    } catch (e) {
      this.state.error = `移动失败（已成功 ${succeeded} 本）：${Logger.errText(e as BusinessError)}`;
    }
    // 无论成败都刷新：部分成功时列表必须反映真实状态
    await this.refresh();
    return succeeded;
  }

  /**
   * 书架全部书籍（**不分组**，用于选择页）。
   *
   * ⚠️ 刻意不复用 `state.books`：那份列表受**当前分组筛选**影响
   * （用户在"第 1 组"里点"添加书籍"，只能看到第 1 组的书就荒谬了）。
   * 选择页需要的是"我导入过的全部书"，所以这里独立查一次。
   */
  async listAllBooks(): Promise<Book[]> {
    try {
      return await BookRepository.listShelf(BookSort.ADDED, null);
    } catch (e) {
      this.state.error = `加载书籍失败：${Logger.errText(e as BusinessError)}`;
      return [];
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
       * ⚠️ 分组被删后必须刷新首页：它作为"一本书"的条目要消失，
       * 组内那些书会回到首页（`group_id` 被置空 ⇒ 变成未分组 ⇒ 出现在首页）。
       */
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

  /**
   * 分组详情页用：取该分组下的书 + 分组本身。
   *
   * ⚠️ 分组可能已被删除（用户从别的入口删了、或数据异常），
   * 此时返回 `null` 让页面走错误态 —— 不要返回一个空名字的
   * `BookGroup` 让页面显示"「」"。
   */
  async loadGroupDetail(groupId: number): Promise<BookGroup | null> {
    try {
      const group: BookGroup | null = await GroupRepository.getById(groupId);
      if (group === null) {
        return null;
      }
      const books: Book[] = await BookRepository.listShelf(this.state.sort, groupId);
      /**
       * ⚠️ 数量以**实际查到的书**为准，不用 `group.bookCount`：
       * 那是首页列表里的快照，可能已经过期（比如刚在组内移出过书）。
       * 显示与实际列表不一致比数字旧一点更糟。
       */
      group.bookCount = books.length;
      this.detailBooks = books;
      return group;
    } catch (e) {
      this.state.error = `加载分组失败：${Logger.errText(e as BusinessError)}`;
      return null;
    }
  }

  /**
   * 分组详情页的书单（由 `loadGroupDetail` 填充）。
   *
   * ⚠️ 单独放一个字段、不复用 `state.books`：
   * `state.books` 是**首页**的列表（未分组的书）。若把组内的书写进去，
   * 返回首页时首页会短暂显示组内的书 —— 而首页的语义是"未分组的书"，
   * 那会是一个可见的错乱。
   */
  detailBooks: Book[] = [];

  clearError(): void {
    this.state.error = '';
  }
}
