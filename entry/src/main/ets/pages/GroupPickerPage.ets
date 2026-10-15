import { Book } from '../model/Book';
import { RouteParam } from '../model/RouteParam';
import { BookGroup } from '../model/BookGroup';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { GroupRepository } from '../data/repository/GroupRepository';
import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { Logger } from '../common/utils/Logger';
import { EmptyView } from '../views/common/EmptyView';
import { LoadingView } from '../views/common/LoadingView';

/**
 * 「把已导入的书加入分组」页。
 *
 * 版面（自上而下）：
 * ```
 * ‹ 返回        加入「科幻」        全选
 * ───────────────────────────────────────
 * ☑ 三体
 * ☐ 球状闪电            ← 已在别组的会标注当前分组
 * ☑ 超新星纪元
 * ───────────────────────────────────────
 *        已选 2 本    [ 加入分组 ]
 * ```
 *
 * ⚠️ **这一页为什么必须存在**（用户实测反馈）：
 * 分组本身只是个标签，真正要做的事是"**从已导入的书里挑**"。
 * 早期只实现了"新建/重命名/删除分组"，没有任何入口能把书放进分组 ——
 * 于是分组永远是空的，整个功能等于没做。
 * 判据：**一个"归类"功能，必须同时提供"建类"和"把东西放进类"两条路**，
 * 只做前者就是半成品。
 *
 * ⚠️ 数据来源：书籍列表来自 `vm.listAllBooks()`（**不带分组筛选**），
 * 不是 `vm.state.books` —— 后者受书架当前选中的分组影响，
 * 在"第 1 组"里点"添加书籍"却只能看到第 1 组的书，逻辑上就说不通。
 *
 * ⚠️ 配色走 `AppColor`（跟随系统深浅色），与书架页一致：
 * 本页属于书架流程，不是阅读页内部（那边才用 `ReaderTheme`）。
 */
@Entry
@Component
struct GroupPickerPage {
  /** 安全区高度（vp），沉浸式全屏的配套让位 */
  @StorageProp('safeAreaTop') safeAreaTop: number = 0;
  @StorageProp('safeAreaBottom') safeAreaBottom: number = 0;

  /**
   * 与书架页共享的 ViewModel（通过 `ShelfRefreshRegistry` 取）。
   *
   * ⚠️ 不能在本页 `new`：那样移动完书之后，书架页那份 `state.books`
   * 不会刷新，返回书架看到的还是旧分组。
   */
  private vm: BookShelfViewModel | null = null;

  /** 目标分组 id；-1 表示"未分组"（把书移出所有分组） */
  private targetGroupId: number = -1;
  /**
   * 目标分组名（显示在标题上）。
   *
   * ⚠️ 初值是**空串**而不是 `'未分组'`：空串表示"路由没传名字"，
   * 于是 `loadAll` 里的兜底查询才有机会执行。若初值写成 `'未分组'`，
   * "没传名字"与"传的就是未分组"就无法区分，兜底查询会被永远跳过。
   * 真正显示时由 `displayGroupName()` 统一兜底。
   *
   * ⚠️ 用 `@State` 而不是普通成员：它由路由参数在 `aboutToAppear` 里赋值，
   * 而普通成员的赋值**不会触发重绘** —— 首帧标题会停在初始值上。
   */
  @State private targetGroupName: string = '';

  @State private books: Book[] = [];
  /**
   * 已勾选的书籍 id。
   *
   * ⚠️ 用 `number[]` 而不是 `Set<number>`：ArkTS 对 `Set` 的
   * 状态观察支持不如数组可靠（`@State` 对 Set 的增删不保证触发重绘），
   * 而这里最多几百本，`includes` 的线性查找完全可以接受。
   */
  @State private selectedIds: number[] = [];
  @State private loading: boolean = true;
  @State private error: string = '';
  /** 正在提交（防连点） */
  @State private submitting: boolean = false;
  /**
   * 全部分组（用于把 `book.groupId` 翻成名字）。
   *
   * ⚠️ 用数组 + 线性查找，**不用 `Map`**：
   *  - 分组数量是个位到十几个，线性查找的代价可忽略；
   *  - 全项目没有任何一处用 `Map`/`Set`，一律用普通数组 ——
   *    保持一致比"这里更优雅"重要（ArkTS 对集合类型的行为细节与
   *    标准 TS 并不完全一致，引入它等于引入一处没有先例的用法）。
   *
   * ⚠️ 用普通成员而不是 `@State`：它在 `loadAll` 里**一次性建好**，
   * 之后只读不改，不需要驱动重绘。
   */
  private groups: BookGroup[] = [];

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as RouteParam | null;
    if (params !== null && params !== undefined) {
      this.targetGroupId = params.groupId;
      /**
       * ⚠️ 名字**直接用路由传来的值**，不再去查库（见 `RouteParam.groupName`）：
       * 查库是异步的，而首帧渲染发生在它完成之前；更关键的是
       * 首帧就已经确定的分组名没必要再绕一次 IO。
       * 只有传空时才退回按 id 查（防御性兜底，正常路径不会走到）。
       */
      if (params.groupName.length > 0) {
        this.targetGroupName = params.groupName;
      }
    }
    this.vm = ShelfRefreshRegistry.current;
    if (this.vm === null) {
      this.error = '书架数据已失效，请回书架重试';
      this.loading = false;
      return;
    }
    this.loadAll().catch((e: Object) => {
      this.error = `加载失败：${Logger.errText(e)}`;
      this.loading = false;
    });
  }

  /** 加载"全部已导入的书" + 分组表 */
  private async loadAll(): Promise<void> {
    const vm: BookShelfViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    try {
      // ① 全部书（不带分组筛选）
      this.books = await vm.listAllBooks();
      /**
       * ② 分组表：一次查完。
       *
       * ⚠️ 它的作用是**把每本书的 `groupId` 翻成名字**（列表第二行要显示
       * "当前：科幻"）。目标分组名已由路由参数给定，这里只在**没传**时
       * 才顺手兜底查一次（正常路径不会走到）。
       */
      this.groups = await GroupRepository.listAll();
      if (this.targetGroupName.length === 0) {
        // 兜底：路由没传名字时按 id 查一次（正常路径不会走到）
        this.targetGroupName = this.groupNameOf(this.targetGroupId);
      }
      this.error = '';
    } catch (e) {
      this.error = `加载失败：${Logger.errText(e as Object)}`;
    } finally {
      this.loading = false;
    }
  }

  /**
   * 标题上显示的分组名（统一兜底）。
   *
   * ⚠️ 空串会渲染成 `加入「」`，所以显示前必须兜一次。
   * 兜底值按目标类型给：id < 0 是"未分组"，否则是"未知分组"
   * （后者只在数据异常时出现 —— 分组被删了但页面还开着）。
   */
  private displayGroupName(): string {
    if (this.targetGroupName.length > 0) {
      return this.targetGroupName;
    }
    return this.targetGroupId < 0 ? '未分组' : '未知分组';
  }

  /** 按 id 查分组名；没有返回空串（表示未分组） */
  private groupNameOf(groupId: number | null): string {
    if (groupId === null) {
      return '';
    }
    for (const group of this.groups) {
      if (group.id === groupId) {
        return group.name;
      }
    }
    return '';
  }

  /** 这本书是否已勾选 */
  private isSelected(bookId: number): boolean {
    return this.selectedIds.includes(bookId);
  }

  /** 勾选/取消勾选一本 */
  private toggleSelect(bookId: number): void {
    if (this.isSelected(bookId)) {
      /**
       * ⚠️ 重新赋一个新数组，而不是 `splice` 原地改：
       * `@State` 对数组的**原地修改**在部分版本上观察不到，
       * 会出现"点了勾选框但界面没变"。整体替换是可靠的做法
       * （与书架 `reloadData` 里"整体替换 books 数组"同一个理由）。
       */
      const next: number[] = [];
      for (const id of this.selectedIds) {
        if (id !== bookId) {
          next.push(id);
        }
      }
      this.selectedIds = next;
      return;
    }
    const added: number[] = this.selectedIds.slice();
    added.push(bookId);
    this.selectedIds = added;
  }

  /** 全选 / 全不选 */
  private toggleSelectAll(): void {
    if (this.selectedIds.length === this.books.length && this.books.length > 0) {
      this.selectedIds = [];
      return;
    }
    const all: number[] = [];
    for (const book of this.books) {
      all.push(book.id);
    }
    this.selectedIds = all;
  }

  /**
   * 提交：把勾选的书加入目标分组。
   *
   * ⚠️ 必须**如实反馈成功数量**（见 `moveManyToGroup` 的说明）：
   * 勾了 20 本只成功 18 本却提示"已加入"，用户会以为全部放好了。
   */
  private submit(): void {
    const vm: BookShelfViewModel | null = this.vm;
    if (vm === null || this.submitting || this.selectedIds.length === 0) {
      return;
    }
    this.submitting = true;
    /**
     * ⚠️ `targetGroupId < 0` 要传 `null`（未分组），不是传 -1：
     * 数据层把 `null` 当作"清空 group_id"，传 -1 会写进一个不存在的分组 id，
     * 那本书就会从**任何**分组视图里消失（包括"全部"之外的筛选）。
     */
    const groupId: number | null = this.targetGroupId < 0 ? null : this.targetGroupId;
    const count: number = this.selectedIds.length;
    vm.moveManyToGroup(this.selectedIds, groupId).then((succeeded: number) => {
      /**
       * ⚠️ 部分失败时**不返回**，让用户能重试剩下的：
       * 直接 `back()` 会让他以为全部成功，而且没有机会补救。
       */
      if (succeeded < count) {
        this.submitting = false;
        this.error = succeeded > 0
          ? `已加入 ${succeeded} 本，${count - succeeded} 本失败，可重试`
          : (vm.state.error.length > 0 ? vm.state.error : '加入分组失败');
        vm.clearError();
        return;
      }
      this.getUIContext().getRouter().back();
    }).catch((e: Object) => {
      this.submitting = false;
      this.error = `加入分组失败：${Logger.errText(e)}`;
    });
  }

  build() {
    Column() {
      this.buildHeader()
      Divider().color(AppColor.divider)

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.danger)
          .width('100%')
          .padding({
            left: AppTheme.PAGE_PADDING,
            right: AppTheme.PAGE_PADDING,
            top: AppTheme.GAP_S
          })
      }

      if (this.loading) {
        LoadingView({ message: '正在加载书籍…' })
      } else if (this.books.length === 0) {
        /**
         * ⚠️ 空状态必须包在带 `layoutWeight(1)` 的 `Column` 里：
         * `EmptyView` 自身是 `height('100%')`，取父容器高度 ——
         * 直接放在本页的 Column 里会把头部顶出可视区（目录页记过同类坑）。
         */
        Column() {
          EmptyView({
            title: '书架里还没有书',
            hint: '先在书架导入 TXT，再回来把它们放进分组',
            actionText: '返回书架',
            onAction: () => {
              this.getUIContext().getRouter().back();
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        this.buildBookList()
        this.buildActionBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bgPage)
    .padding({ top: this.safeAreaTop, bottom: this.safeAreaBottom })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  buildHeader() {
    Stack({ alignContent: Alignment.Start }) {
      /**
       * 标题写清"要加入哪个分组"：用户点进来时最想确认的就是这件事。
       * ⚠️ 分组名可能很长，必须截断，否则会把右侧的"全选"挤出去。
       */
      Text(`加入「${this.displayGroupName()}」`)
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .height(48)
        .textAlign(TextAlign.Center)
        .padding({ left: 72, right: 72 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row() {
        Text('‹ 返回')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppColor.textPrimary)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .onClick(() => {
            // 返回 = 不修改任何东西（未提交的选择自然丢弃）
            this.getUIContext().getRouter().back();
          })

        Blank()

        /**
         * 全选/全不选：几十本书逐本勾太累，尤其"把大部分书放进一个组"是常见操作。
         * ⚠️ 文案随状态切换，让用户知道点下去会发生什么（切换类按钮的通用做法）。
         */
        Text(this.selectedIds.length === this.books.length && this.books.length > 0
          ? '全不选'
          : '全选')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppColor.accent)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .onClick(() => {
            this.toggleSelectAll();
          })
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  @Builder
  buildBookList() {
    List({ space: AppTheme.GAP_S }) {
      ForEach(this.books, (book: Book) => {
        ListItem() {
          Row({ space: AppTheme.GAP_M }) {
            /**
             * 勾选框：用字形而不是 `Checkbox` 组件。
             *
             * ⚠️ 理由与项目"零图片依赖"一致：`Checkbox` 自带一套主题色与尺寸，
             * 在深浅模式下要额外调参；字形跟着 `fontColor` 走，天然一致。
             * 且整个 ListItem 都可点，热区比一个 20vp 的方框大得多。
             */
            Text(this.isSelected(book.id) ? '☑' : '☐')
              .fontSize(20)
              .fontColor(this.isSelected(book.id) ? AppColor.accent : AppColor.textHint)

            Column({ space: 4 }) {
              Text(book.title)
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppColor.textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              /**
               * 第二行：当前分组 + 章节数。
               * ⚠️ "当前分组"是必须的：用户要能看出这本书是**新增**到目标组，
               * 还是**从别的组挪过来**（后者会离开原来的组）。
               */
              Text(this.subtitleOf(book))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppColor.textHint)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding(AppTheme.GAP_M)
          .backgroundColor(AppColor.bgCard)
          .borderRadius(AppTheme.ITEM_RADIUS)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.toggleSelect(book.id);
          })
        }
      }, (book: Book) => book.listKey())
    }
    .width('100%')
    .layoutWeight(1)
    .padding({
      left: AppTheme.PAGE_PADDING,
      right: AppTheme.PAGE_PADDING,
      top: AppTheme.GAP_S,
      bottom: AppTheme.GAP_S
    })
    .cachedCount(6)
    .scrollBar(BarState.Off)
  }

  /**
   * 列表第二行：当前分组 + 章节数。
   *
   * ⚠️ 已在本组的书要**明确说"已在此分组"**：否则用户会以为还得再勾一次，
   * 或者担心重复操作会出问题（实际上重复设置是幂等的）。
   */
  private subtitleOf(book: Book): string {
    const chapters: string = `${book.totalChapters} 章`;
    const current: string = this.groupNameOf(book.groupId);
    if (current.length === 0) {
      return `未分组 · ${chapters}`;
    }
    if (this.targetGroupId >= 0 && book.groupId === this.targetGroupId) {
      return `已在此分组 · ${chapters}`;
    }
    return `当前：${current} · ${chapters}`;
  }

  @Builder
  buildActionBar() {
    Row({ space: AppTheme.GAP_M }) {
      /**
       * ⚠️ 未勾选任何书时按钮**置灰且不可点**：没有目标时提交是无意义的，
       * 而"点了没反应"会让人怀疑程序坏了。
       */
      Button(this.submitting
        ? '正在加入…'
        : (this.selectedIds.length > 0
          ? `加入分组（${this.selectedIds.length}）`
          : '加入分组'))
        .fontSize(AppTheme.FONT_BODY)
        .layoutWeight(1)
        .height(44)
        .backgroundColor(AppColor.primary)
        .fontColor(AppColor.onPrimary)
        .enabled(!this.submitting && this.selectedIds.length > 0)
        .onClick(() => {
          this.submit();
        })
    }
    .width('100%')
    .padding({
      left: AppTheme.PAGE_PADDING,
      right: AppTheme.PAGE_PADDING,
      top: AppTheme.GAP_M,
      bottom: AppTheme.GAP_M
    })
    .backgroundColor(AppColor.bgCard)
  }
}
