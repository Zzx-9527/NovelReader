// ⚠️ 已不 import promptAction：所有系统弹窗（showActionMenu/showDialog）
// 已替换为 ThemeMenu / ThemeConfirm（views/common/），文案与配色走令牌体系。
import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { ShelfEntry } from '../model/ShelfEntry';
import { ShelfState } from '../viewmodels/ShelfState';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { BookSort } from '../data/repository/BookRepository';
import { StorageBootstrap } from '../common/StorageBootstrap';
import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { AppFont } from '../common/theme/AppFont';
import { Encodings } from '../common/utils/EncodingDetector';
import { Logger } from '../common/utils/Logger';
import { LoadingView } from '../views/common/LoadingView';
import { EmptyView } from '../views/common/EmptyView';
import { ErrorView } from '../views/common/ErrorView';
import { BookGridItem } from '../views/bookshelf/BookGridItem';
import { BookListItem } from '../views/bookshelf/BookListItem';
import { GroupGridItem } from '../views/bookshelf/GroupGridItem';
import { GroupListItem } from '../views/bookshelf/GroupListItem';
import { ContinueReadingCard } from '../views/bookshelf/ContinueReadingCard';
import { ShelfSkeleton } from '../views/bookshelf/ShelfSkeleton';
import { TextInputDialog } from '../views/common/TextInputDialog';
import { ThemeMenu } from '../views/common/ThemeMenu';
import { ThemeConfirm } from '../views/common/ThemeConfirm';
import { RouteName, RouteParam } from '../model/RouteParam';

/**
 * 书架页。
 *
 * 分层约定：本页只调用 ViewModel，不 import 任何 Repository / database。
 *
 * ⚠️ **状态对象与 ViewModel 必须成对传入，且必须调用 `vm.bind(state)`。**
 *
 * 这不是可选的美化：`ShelfState` 是 `@Observed` + 本页 `@ObjectLink`，
 * 而 ViewModel 把数据写进 `vm.state`。若两者不是**同一个对象实例**，
 * 就会出现"数据早就加载好了，UI 却永远停在 loading"这类故障
 * （`ShelfState.loading` 初值为 true，没人把它改回 false）。
 *
 * 所以由根页面 `Index` 持有这一对实例并传进来：
 *  - 状态跟着根页面走 → 切 Tab 不丢滚动位置与分组选择；
 *  - ShelfRefreshRegistry 注册的也是同一个 vm → 刷新链路完整。
 */
@Component
export struct BookShelfPage {
  /**
   * 与根页面共享的 `@Observed` 状态。
   * `@ObjectLink` 而非 `@State`：后者接收参数时只做顶层赋值，
   * 观察不到对象**内部字段**（books/loading/error）的变化。
   */
  @ObjectLink state: ShelfState;
  /** 与根页面共享的 ViewModel；由 `Index` 构造并传入 */
  private vm!: BookShelfViewModel;

  /**
   * 分组管理弹窗是否可见。
   *
   * ⚠️ 这些是**本页的临时交互状态**，不进 `ShelfState`：
   * 它们只服务一次弹窗交互，与书架数据无关；放进 `@Observed` 状态对象
   * 会让"打开一个弹窗"也去驱动整个书架列表重绘。
   */
  @State private groupDialogVisible: boolean = false;
  /**
   * 书名搜索框是否展开。
   *
   * ⚠️ 纯视图状态（见 build 内搜索框的说明）：不进 `ShelfState`，
   * 收起时**不清空关键词** —— 重新展开还在，用户切走再看一眼的需求是连续的。
   * 只有清空（✕）才真正把列表恢复全量。
   */
  @State private searchVisible: boolean = false;
  /** 弹窗是"新建"还是"重命名"；重命名时用 `editingGroupId` 记住改的是哪一个 */
  @State private editingGroupId: number = -1;
  /** 重命名时输入框的初值 */
  @State private editingGroupName: string = '';

  // ── 主题化菜单/确认弹窗的挂载状态 ────────────────────────
  /**
   * 当前显示的 ThemeMenu 内容。
   *
   * ⚠️ 用"一个可选对象 + visible 位"而不是多个 boolean：
   * 菜单有 6 处调用点，每处一份 boolean + 一份标题 + 一份选项数组
   * 会把 build() 炸成 6 个 if；收成一份状态，build 里只有一个 if。
   * `danger` 用字符串（"2,3"）与 ThemeMenu 的 @Prop 对齐（见组件注释）。
   */
  @State private menuVisible: boolean = false;
  @State private menuTitle: string = '';
  @State private menuOptions: string[] = [];
  @State private menuDanger: string = '';
  @State private menuCurrent: number = -1;
  private menuOnPick: ((index: number) => void) | null = null;

  /** 确认弹窗（ThemeConfirm）的挂载状态，与菜单同理收敛为一份 */
  @State private confirmVisible: boolean = false;
  @State private confirmTitle: string = '';
  @State private confirmMessage: string = '';
  @State private confirmText: string = '确定';
  @State private confirmDanger: boolean = false;
  private confirmOnYes: (() => void) | null = null;

  aboutToAppear(): void {
    // 关键一步：让 ViewModel 与 UI 操作同一个状态对象。
    // 必须在 init() 之前 —— init() 会写 state.gridMode/sort。
    this.vm.bind(this.state);

    // 注册到根页面：onPageShow 只对 @Entry 页面触发，普通 @Component 指望不上，
    // 所以由根页面在"从阅读页返回 / 切回书架 Tab"时显式调用 refreshFromHost()。
    ShelfRefreshRegistry.current = this.vm;
    StorageBootstrap.ensureReady().then(() => {
      this.vm.init();
    }).catch((e: Object) => {
      this.state.error = `初始化失败：${Logger.errText(e)}`;
      this.state.loading = false;
    });
  }

  aboutToDisappear(): void {
    if (ShelfRefreshRegistry.current === this.vm) {
      ShelfRefreshRegistry.current = null;
    }
    this.vm.dispose();
  }

  /** 由根页面调用：重载书架数据 */
  refreshFromHost(): void {
    this.vm.reloadData();
  }

  build() {
    /**
     * ⚠️ 外层用 `Stack` 是为了让分组弹窗能**盖住整页**。
     *
     * 若把弹窗作为 `Column` 的最后一个子节点，它会参与布局、把上面的列表挤短
     * （弹窗自己 `height('100%')`，会把父容器撑爆）；而 `Stack` 是层叠语义，
     * 后画的浮层盖在前面内容之上，不影响列表布局 —— 与 `ReaderPage` 的分层
     * 是同一套做法。
     */
    Stack() {
      Column() {
        this.buildHeader()

        /**
         * ⚠️ 加载态与错误态的判据都要求"**完全没有内容**"
         * （分组与散书都为 0），不能只看 `books`。
         *
         * 只看 `books` 的话：一个只有分组、没有散书的书架在刷新时会
         * 闪出"正在加载书架…"，出错时更是整屏替换成错误页 ——
         * 而分组条目明明还能正常点进去。判据要覆盖**这一页实际会渲染的东西**。
         */
        if (this.state.loading && this.state.books.length === 0
          && this.state.groups.length === 0) {
          /**
           * ⚠️ 首屏加载与"重新解析"**必须分开**，不能用同一个占位：
           *
           *  - 首次加载 → **骨架屏**（`ShelfSkeleton`）：它按真实版面铺块，
           *    加载完成时是"占位块被内容替换"，位置与尺寸都不变，零跳变；
           *  - 重新解析 → 保留转圈 + 文案：这是一个**有明确文案的过程**
           *    （用户刚点完"换编码"，需要知道正在做什么），
           *    而它的时长不可预测（大文件可能十几秒），骨架屏在这里
           *    反而会让人以为"书已经在加载了"。
           *
           * 判据：**知道要出现什么形状 → 骨架屏；只知道"在处理" → 转圈 + 文案。**
           */
          if (this.state.reparsing) {
            LoadingView({ message: '正在重新解析…' })
          } else {
            ShelfSkeleton()
          }
        } else if (this.state.error.length > 0 && this.state.books.length === 0
          && this.state.groups.length === 0) {
          ErrorView({
            message: this.state.error,
            /**
             * ⚠️ 提示里必须补上「已导入的文件不会丢失」。
             *
             * 书架报错时，用户最怕的不是"读不出来"，而是"我的书是不是没了" ——
             * 而这两件事在这里是完全独立的：错误来自**读库/读索引**，
             * 书源文件一直躺在沙箱里。把这句话说在前面，用户才敢按"重试"
             * 而不是先去文件管理器翻。
             *
             * 判据：**错误文案要同时说"怎么了"和"我最怕的那件事没发生"**，
             * 只给一个动作（重试）是不够的。
             */
            hint: '下拉重试，或检查存储权限。已导入的文件不会丢失。',
            actionText: '重试',
            onRetry: () => {
              this.vm.clearError();
              this.vm.refresh();
            }
          })
        } else if (this.state.isEmptyShelf) {
          /**
           * **首页完全为空** → 引导导入。
           *
           * ⚠️ 判据是 `isEmptyShelf`，它同时看**分组与散书**：
           * 只有分组、没有散书时不该显示这一屏 —— 用户会以为分组也没了，
           * 而分组恰恰是他自己建的。
           */
          EmptyView({
            title: '书架还是空的',
            hint: '导入一本本地 TXT 小说开始阅读。所有文件都保存在本机，不会上传。',
            actionText: '导入 TXT',
            onAction: () => {
              this.doImport();
            }
          })
        } else {
          this.buildBookList()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.bgPage)

      /**
       * 分组新建/重命名弹窗（最上层）。
       *
       * ⚠️ 用同一个弹窗承载"新建"与"重命名"两种用途，靠 `editingGroupId`
       * 区分（-1 = 新建）—— 两者的界面与校验完全一样，
       * 做两个组件只会让"改了一处忘了另一处"。
       */
      if (this.groupDialogVisible) {
        TextInputDialog({
          title: this.editingGroupId < 0 ? '新建分组' : '重命名分组',
          label: this.editingGroupId < 0 ? '' : '输入新的分组名',
          placeholder: '分组名，最多 20 字',
          initialValue: this.editingGroupName,
          confirmText: this.editingGroupId < 0 ? '创建' : '保存',
          onConfirm: (value: string) => {
            this.submitGroupDialog(value);
          },
          onCancel: () => {
            this.groupDialogVisible = false;
          }
        })
      }

      /**
       * 主题化动作菜单（替代系统 showActionMenu）：全页共用一个实例，
       * 内容由 `menu*` 状态驱动 —— 6 处调用点只改状态、不改结构。
       */
      if (this.menuVisible) {
        ThemeMenu({
          title: this.menuTitle,
          options: this.menuOptions,
          dangerIndexes: this.menuDanger,
          currentIndex: this.menuCurrent,
          onPick: (index: number) => {
            this.menuVisible = false;
            const cb = this.menuOnPick;
            if (cb !== null) {
              cb(index);
            }
          },
          onClose: () => {
            this.menuVisible = false;
          }
        })
      }

      /**
       * 主题化确认弹窗（替代系统 showDialog / AlertDialog）。
       * 确认按钮的回调 `confirmOnYes` 存普通成员：它只在弹窗打开期间有效，
       * 不需要驱动重绘（与 `menuOnPick` 同理）。
       */
      if (this.confirmVisible) {
        ThemeConfirm({
          title: this.confirmTitle,
          message: this.confirmMessage,
          confirmText: this.confirmText,
          danger: this.confirmDanger,
          onConfirm: () => {
            this.confirmVisible = false;
            const cb = this.confirmOnYes;
            if (cb !== null) {
              cb();
            }
          },
          onCancel: () => {
            this.confirmVisible = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  // ------------------------------------------------------------ 头部

  /**
   * 标题行下方的**计数副标题**。
   *
   * ⚠️ 空书架时返回空串、调用方整行不渲染：
   * 首屏加载中书架是空的，此时显示「0 本」会与骨架屏自相矛盾
   * （骨架屏说"马上有一屏书"，副标题说"一本都没有"）。
   * 而真的空书架会走 `EmptyView` 那一屏，也不需要这个计数。
   *
   * ⚠️ 用「组」而不是「个分组」：标题行右侧还有四个操作，
   * 副标题的可用宽度只有一百多 vp，多两个字就会被省略号截断。
   */
  private shelfCountText(): string {
    const books: number = this.state.books.length;
    const groups: number = this.state.groups.length;
    if (books === 0 && groups === 0) {
      return '';
    }
    if (groups === 0) {
      return `${books} 本`;
    }
    return `${books} 本 · ${groups} 组`;
  }

  /**
   * 头部：标题 + 计数 + 操作，下面一条**通栏发丝线**。
   *
   * ⚠️ 本次从"一行挤下标题与四个操作"改成**两行**，理由是量出来的：
   * 三个胶囊（约 50 / 50 / 62vp）+「导入」（约 56vp）+ 四个 8vp 间距
   * 已经占掉 218+32 = 250vp，而整行可用 328vp —— 留给标题的只有 78vp。
   * 「书架」占 40vp，副标题需要约 76vp，**零余量**：任何字体差异都会
   * 把计数截成省略号。分两行之后标题拿到全部宽度，操作行也不必再压字号。
   *
   * ⚠️ 发丝线**通栏**（左右都不留 16vp 内边距）：它是一条"版面分隔"，
   * 而不是某个块的外框。出血到屏幕两边才读得出这个意思。
   * 为此它必须挂在**不带内边距**的容器上，所以本 `@Builder` 分了三段：
   * 带内边距的标题行 / 通栏线 / 带内边距的后续块。
   */
  @Builder
  buildHeader() {
    Column() {
      // ① 标题 + 计数 + 「更多」图标
      Row({ space: AppTheme.GAP_S }) {
        Column({ space: 4 }) {
          Text('书架')
            .fontSize(AppTheme.FONT_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
            // 标题落衬线（探测到才有）：与书名、分组名同一套题字语汇
            .fontFamily(AppFont.titleFamily())
            .letterSpacing(AppTheme.TRACK_TITLE)

          if (this.shelfCountText().length > 0) {
            Text(this.shelfCountText())
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppColor.textHint)
              .fontFeature(AppFont.TABULAR)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        /**
         * 「更多」图标：**列表/排列/新建分组/导入** 四个动作的唯一入口
         * （用户要求合并）。`more.svg`（三点竖排），`fillColor` 染色。
         *
         * ⚠️ **绝不要给固定尺寸的 `Image` 加 `padding`**（`GroupDetailPage`
         * 实测踩过：padding 向内挤，20vp 的图标区域被 24vp 的 padding 压成 0，
         * 图标整个画不出来）。热区靠外层 `Row` 撑，`onClick` 也绑在 Row 上。
         *
         * ⚠️ 导入进行中置灰：四个动作里只有导入是重操作，
         * 解析期间把它单独禁用即可，不影响其余三项弹出。
         */
        Row() {
          Image($r('app.media.more'))
            .width(20)
            .height(20)
            .objectFit(ImageFit.Contain)
            .fillColor(AppColor.textPrimary)
        }
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .onClick(() => {
          this.showHeaderActionsMenu();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: AppTheme.PAGE_PADDING,
        right: AppTheme.PAGE_PADDING,
        top: AppTheme.GAP_M
      })

      /**
       * ②′ 书名搜索框（可折叠）。
       *
       * ⚠️ 默认收起、点放大镜展开：搜索是低频操作，常驻会挤占
       * 标题行下方的黄金位置；展开后自动聚焦，收起时清空关键词，
       * 让列表立刻恢复全量（无 IO，纯内存）。
       *
       * ⚠️ 用 `@State` 本地变量控制显隐，而不是塞进 `ShelfState`：
       * "搜索框开没开"是**视图状态**，不影响任何数据，
       * 放进状态对象会让人以为它参与刷新登记表那套机制。
       */
      if (this.searchVisible) {
        Row({ space: AppTheme.GAP_S }) {
          Image($r('app.media.search'))
            .width(16)
            .height(16)
            .objectFit(ImageFit.Contain)
            .fillColor(AppColor.textHint)

          TextInput({
            text: this.state.searchKeyword,
            placeholder: '搜索书名或分组',
          })
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(AppColor.textPrimary)
            .placeholderColor(AppColor.textHint)
            .placeholderFont({ size: AppTheme.FONT_BODY })
            .backgroundColor(Color.Transparent)
            .padding(0)
            .layoutWeight(1)
            .defaultFocus(true)
            .onChange((value: string) => {
              this.vm.setSearchKeyword(value);
            })

          if (this.state.searchKeyword.length > 0) {
            Text('✕')
              .fontSize(AppTheme.FONT_BODY)
              .fontColor(AppColor.textHint)
              .padding({ left: 8, right: 2, top: 8, bottom: 8 })
              .onClick(() => {
                this.vm.setSearchKeyword('');
              })
          }
        }
        .width('100%')
        .padding({ top: 6, bottom: 6, left: 12, right: 12 })
        .margin({ top: AppTheme.GAP_M })
        .border({ width: 1, color: AppColor.divider })
        .borderRadius(AppTheme.CHIP_RADIUS + 3)
      }

      // ③ 通栏发丝线（原②操作行已并入「更多」菜单，这一行直接顶上）
      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)

      /**
       * ④ 状态文案 + 继续阅读卡片。
       *
       * 这两块都必须自己带左右内边距：它们已经不在①③的带内边距容器里了。
       */
      if (this.state.importMessage.length > 0) {
        Text(this.state.importMessage)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textSecondary)
          .width('100%')
          .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })
      }

      if (this.state.reparseMessage.length > 0) {
        Text(this.state.reparseMessage)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
          .width('100%')
          .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })
      }

      /**
       * 继续阅读卡片。
       *
       * ⚠️ 它显示的是**全局**最近在读的一本，不受分组影响 —— 这是对的：
       * 首页本身就是"全部内容"的视图（分组与未分组的书都在这里列），
       * 所以"最近在读哪本"在这里显示没有任何矛盾。
       *
       * ⚠️ 与早期实现的区别：那时分组是**筛选条件**，在"某个分组"视图下
       * 显示一本组外的书会自相矛盾（用户实测反馈过）；
       * 现在分组是**文件夹**（点进去才筛选），首页不存在"当前分组"，
       * 这个矛盾自然消失了。
       *
       * ⚠️ 外面套一层带内边距的 `Column`，而不是给卡片传 margin ——
       * `@Prop`/普通成员的组件不该由调用方决定外边距，
       * 与"组件管画什么、容器管放在哪"是同一条分工。
       */
      if (this.state.continueBook !== null) {
        Column() {
          ContinueReadingCard({
            book: this.state.continueBook ?? undefined,
            onContinue: (book: Book) => {
              this.openReader(book);
            }
          })
        }
        .width('100%')
        .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })
      }
    }
    .width('100%')
  }

  /**
   * 点分组条目 → 进入分组详情页。
   *
   * ⚠️ 名字随路由一起传：目标页要立刻在标题上显示它，
   * 而"自己去查库"是异步的，首帧会先渲染成空标题（详见 `RouteParam.groupName`）。
   */
  private openGroupDetail(group: BookGroup): void {
    const param: RouteParam = new RouteParam();
    param.groupId = group.id;
    param.groupName = group.name;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.GROUP_DETAIL_PAGE, params: param })
      .catch(() => {
        this.toast('打开分组失败');
      });
  }

  // ------------------------------------------------------------ 书籍列表

  /**
   * 书架首页列表：**分组与书籍混排**。
   *
   * ⚠️ 只遍历 `state.entries` 这**一条**数组，而不是"分组一个 `ForEach`、
   * 书一个 `ForEach`"。
   *
   * 后者无论各自怎么排，渲染出来永远是"分组全在前、书全在后" ——
   * 做不到交错，而用户明确要求"分组就相当于一本书"：
   * 刚读完的书必须能排在分组**前面**（用户实测反馈过这一点）。
   *
   * ⚠️ 排序已在 ViewModel 里做完（`buildEntries`），这里**不再排序**：
   * 渲染层只负责画，排序规则收在一处（设计文档第 28 条）。
   * 若在这里再排一次，两处规则迟早会不一致。
   */
  @Builder
  buildBookList() {
    /**
     * 搜索无结果态：**必须**在两种视图前判 ——
     * 空的 `Grid`/`List` 渲染出来是一片空白，用户分不清
     * "没有这本书"和"页面坏了"。
     * ⚠️ 只看"过滤后为空 + 有关键词"：书架本来为空走的是上面的导入引导，
     * 两者语义不同，不能共用一个空态。
     */
    if (this.state.entries.length === 0 && this.state.searchKeyword.trim().length > 0) {
      Column({ space: AppTheme.GAP_M }) {
        Text('没有找到匹配的书')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(AppColor.textSecondary)
        Text(`换个关键词试试（当前：${this.state.searchKeyword.trim()}）`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
      }
      .width('100%')
      .padding({ top: 80 })
    } else if (this.state.gridMode) {
      Grid() {
        ForEach(this.state.entries, (entry: ShelfEntry) => {
          GridItem() {
            /**
             * ⚠️ 按 `isGroup` 分流到两个组件，而不是做一个"万能条目"：
             * 分组与书的**封面逻辑、角标、长按菜单**都不同，
             * 塞进一个组件会到处是 `if (isGroup)`，越写越难读。
             */
            if (entry.isGroup) {
              GroupGridItem({
                group: entry.group,
                onTap: (g: BookGroup) => {
                  this.openGroupDetail(g);
                },
                onLongPress: (g: BookGroup) => {
                  this.showGroupActions(g.id, g.name);
                }
              })
            } else {
              BookGridItem({
                book: entry.book,
                onTap: (b: Book) => {
                  this.openReader(b);
                },
                onLongPress: (b: Book) => {
                  this.showBookActions(b);
                }
              })
            }
          }
        }, (entry: ShelfEntry) => entry.key())
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(AppTheme.GAP_M)
      .rowsGap(AppTheme.GAP_M)
      .padding({
        left: AppTheme.PAGE_PADDING,
        right: AppTheme.PAGE_PADDING,
        top: AppTheme.GAP_M,
        bottom: AppTheme.GAP_L
      })
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    } else {
      /**
       * 列表形态：**整列收成一块卡片**，行与行之间用一根缩进发丝线分开。
       *
       * ⚠️ 原实现是 `List({ space: 8 })` + 每行自己一张 `bgCard` 圆角卡，
       * 六行就是"六张白卡叠在浅灰底上"—— 白/灰交替出现，整列读起来是碎的，
       * 而且**每张卡都在重复表达同一个边界**（这一列本来就是一个整体）。
       *
       * 现在把卡片底挪到 `List` 自己身上：一列只有一条外边界，
       * 内部靠"从文字列开始的缩进线"分区。缩进线而不是通栏线，是因为
       * 通栏线等于又把整块切成一行行的卡 —— 封面那一列必须保持连续，
       * 视觉上才说得通"这是一排书"。
       *
       * ⚠️ 卡片底 + 圆角 + `clip` 都挂在 `List` 上（不是外层 `Column`）：
       * 挂在 `List` 上才能让**滚动内容一起被裁**；挂在外层则滚动时
       * 行会从圆角外面滑出来。这也是把内边距留给外层 `Column` 的原因。
       *
       * ⚠️ `space` 必须去掉（默认 0）：行间现在靠发丝线分区，
       * 再留 8vp 间距会让线悬在两段空白之间，读起来像"断开的表格"。
       */
      Column() {
        List() {
          /**
           * ⚠️ `ForEach` 的 itemGenerator 这里**必须**收第二个参数 `index`：
           * 首行不画线（否则线会顶在卡片上边缘，看起来像卡片缺了个边）。
           * 用 `entry.key()` 做键 —— 排序变化时键跟着变，实例重建，
           * `topRule` 才会跟着重新求值。
           */
          ForEach(this.state.entries, (entry: ShelfEntry, index: number) => {
            ListItem() {
              if (entry.isGroup) {
                GroupListItem({
                  group: entry.group,
                  inset: true,
                  topRule: index > 0,
                  onTap: (g: BookGroup) => {
                    this.openGroupDetail(g);
                  },
                  onLongPress: (g: BookGroup) => {
                    this.showGroupActions(g.id, g.name);
                  }
                })
              } else {
                BookListItem({
                  book: entry.book,
                  inset: true,
                  topRule: index > 0,
                  onTap: (b: Book) => {
                    this.openReader(b);
                  },
                  onLongPress: (b: Book) => {
                    this.showBookActions(b);
                  }
                })
              }
            }
          }, (entry: ShelfEntry) => entry.key())
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(AppColor.bgCard)
        .borderRadius(AppTheme.CARD_RADIUS)
        .clip(true)
        .cachedCount(6)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({
        left: AppTheme.PAGE_PADDING,
        right: AppTheme.PAGE_PADDING,
        top: AppTheme.GAP_M,
        bottom: AppTheme.GAP_L
      })
    }
  }

  // ------------------------------------------------------------ 交互

  /**
   * 导入 TXT：选文件 → 解析 → **跳确认页**（不再直接入库）。
   *
   * ⚠️ 为什么必须经过确认页，而不是"选完就入库 + toast 提示"：
   * 自动编码探测不可能对每个 TXT 都准确，而**编码错了正文就是满屏乱码**。
   * 旧流程只弹一个 toast 说"编码识别为 X"，用户既无法核对分章结果、
   * 也无法在入库前改编码 —— 只能等导入完、进阅读页发现乱码、再回书架长按换编码
   * （那还会连带删掉标注）。确认页把这一步提前到"写库之前"，代价是点一次"导入"。
   *
   * ⚠️ 低置信度不再用 toast 提示：确认页会把编码与分章预览一起摊开给用户看，
   * 比一句一闪而过的提示有用得多（toast 只是"告知"，确认页是"让他确认"）。
   */
  private async doImport(): Promise<void> {
    const preparation = await this.vm.pickAndPrepare();
    if (preparation === null) {
      if (this.state.error.length > 0) {
        this.toast(this.state.error);
        this.vm.clearError();
      }
      return;
    }
    this.openImportConfirm();
  }

  /**
   * 打开导入确认页。
   *
   * ⚠️ 待确认的 `preparation` 由 ViewModel 的 `state.pendingImport` 携带，
   * **不通过路由参数传**：它是含上千个章节对象的复杂结构，
   * 塞进 `router` 的 params 会被序列化/拷贝，既慢又可能丢字段。
   * 路由只负责"打开页面"，数据靠共享的 ViewModel 交接 ——
   * 与 `ReaderJumpRegistry` 的做法同一个理由（复杂数据不走路由）。
   *
   * ⚠️ 确认页取消时负责 `discardPendingImport()` 清理沙箱文件；
   * 本页不清理，否则用户还没看到确认页文件就没了。
   */
  private openImportConfirm(): void {
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.IMPORT_CONFIRM_PAGE })
      .catch(() => {
        // 确认页打不开（理论上不会，已登记在 main_pages.json）：
        // 退回"直接入库"的旧行为，至少不把用户的导入卡死
        this.toast('无法打开确认页，正在直接导入…');
        // ⚠️ 接住 Promise：不接的话失败会被完全静默吞掉（设计文档第 26 条）
        this.commitImportDirectly().catch((e: Object) => {
          this.toast(`导入失败：${Logger.errText(e)}`);
        });
      });
  }

  /** 确认页不可用时的兜底：按探测到的编码直接入库 */
  private async commitImportDirectly(): Promise<void> {
    const bookId: number = await this.vm.commitPendingImport();
    if (bookId > 0) {
      this.toast('导入完成');
    } else if (this.state.error.length > 0) {
      this.toast(this.state.error);
      this.vm.clearError();
    }
  }

  /**
   * 打开主题化菜单（替代系统 showActionMenu 的统一入口）。
   * 6 处调用点只填状态，浮层结构与回调分发都在 build 里那一个 ThemeMenu 上。
   */
  private openThemeMenu(title: string, options: string[], danger: string,
    current: number, onPick: (index: number) => void): void {
    this.menuTitle = title;
    this.menuOptions = options;
    this.menuDanger = danger;
    this.menuCurrent = current;
    this.menuOnPick = onPick;
    this.menuVisible = true;
  }

  /** 打开主题化确认弹窗（替代系统 showDialog / AlertDialog 的统一入口） */
  private openThemeConfirm(title: string, message: string, confirmText: string,
    danger: boolean, onYes: () => void): void {
    this.confirmTitle = title;
    this.confirmMessage = message;
    this.confirmText = confirmText;
    this.confirmDanger = danger;
    this.confirmOnYes = onYes;
    this.confirmVisible = true;
  }

  /**
   * 标题栏「更多」图标的动作菜单：**列表/排列/新建分组/导入** 四项。
   *
   * ⚠️ 文案与下标由同一个数组推导（设计文档第 28 条）——
   * 插入一项就会"点了 A 执行 B"，先收集项、再用同一数组取下标。
   *
   * ⚠️ 第一项「网格/列表」的文案随当前形态切换：它显示的是
   * **点下去会变成什么**（与阅读页"夜间/日间"按钮同一语义）。
   */
  private showHeaderActionsMenu(): void {
    const actions: string[] = [
      this.state.gridMode ? '切换为列表' : '切换为网格',
      '搜索书名',
      '排列',
      '新建分组',
      this.state.importing ? '正在导入…' : '导入 TXT'
    ];

    this.openThemeMenu('书架', actions, '', -1, (index: number) => {
      const picked: string = actions[index];
      if (picked === undefined) {
        return;
      }
      if (picked === actions[0]) {
        this.vm.toggleGridMode();
      } else if (picked === '搜索书名') {
        this.searchVisible = true;
      } else if (picked === '排列') {
        this.showSortMenu();
      } else if (picked === '新建分组') {
        this.openCreateGroupDialog();
      } else if (picked === '导入 TXT') {
        this.doImport();
      }
    });
  }

  private showSortMenu(): void {
    const actions: string[] = ['最近阅读', '导入时间', '书名'];
    const currentIndex: number = this.state.sort === BookSort.LAST_READ ? 0
      : this.state.sort === BookSort.ADDED ? 1 : 2;

    this.openThemeMenu('书架排序', actions, '', currentIndex, (index: number) => {
      if (index === 0) {
        this.vm.changeSort(BookSort.LAST_READ);
      } else if (index === 1) {
        this.vm.changeSort(BookSort.ADDED);
      } else if (index === 2) {
        this.vm.changeSort(BookSort.TITLE);
      }
    });
  }

  /**
   * 长按书籍的动作菜单。
   *
   * ⚠️ 按钮文案与下标**必须由同一个数组推导**，不能各写一份：
   * 插入一项就会"点了 A 执行 B"（设计文档第 28 条）。
   * 所以这里先收集要显示的项，再用同一个数组去取用户点了哪一项。
   */
  private showBookActions(book: Book): void {
    const actions: string[] = ['开始阅读', '书籍详情'];
    /**
     * ⚠️ 「移入分组」只在**已有分组**时出现。
     *
     * 一个分组都没有时，点它只能弹一个"还没有分组"的空菜单 —— 那是死路。
     * 用户要建组应该走标题行的「＋分组」。
     * 判据：**菜单项要么能用，要么不显示**，不要放一个只会报错的入口。
     */
    const canGroup: boolean = this.state.groups.length > 0;
    if (canGroup) {
      actions.push('移入分组');
    }
    actions.push('换编码（正文乱码时用）');
    actions.push('从书架移除');

    // 危险项（移除）的下标：最后一个
    const dangerIndex: string = `${actions.length - 1}`;

    this.openThemeMenu(book.title, actions, dangerIndex, -1, (index: number) => {
      const picked: string = actions[index];
      if (picked === undefined) {
        return;
      }
      if (picked === '开始阅读') {
        this.openReader(book);
      } else if (picked === '书籍详情') {
        this.openBookDetail(book);
      } else if (picked === '移入分组') {
        this.showGroupPicker(book);
      } else if (picked === '换编码（正文乱码时用）') {
        this.showEncodingPicker(book);
      } else if (picked === '从书架移除') {
        this.vm.removeBook(book.id).then(() => {
          this.toast('已移出书架');
        }).catch(() => {
          this.toast('移除失败');
        });
      }
    });
  }

  /**
   * 单本书 → 选一个分组放进去。
   *
   * ⚠️ **不列「未分组」**（用户要求，也是一个死项）：本菜单只在书架首页
   * 长按书籍时弹出，而首页列出的书**必然都是未分组的**（已归组的书
   * 只出现在分组里）—— 所以「未分组」在这里永远是"（当前）"，
   * 点了不会有任何变化。把一个必然无效的入口摆在第一行，
   * 既占位置又让人以为能点。
   *
   * 「移出分组」的入口在**分组详情页**：那里的书才真的在组里
   * （见 `GroupDetailPage.showBookActions`）。
   *
   * ⚠️ 当前所在的分组标上「（当前）」：让用户知道点了会不会有变化。
   * 菜单最多五项，分组超过五个时截断并提示 —— 想一次挑很多本走
   * 「移入分组」页的批量入口（见 `openGroupPickerForTarget`）。
   */
  private showGroupPicker(book: Book): void {
    const groups: BookGroup[] = this.state.groups;
    /**
     * ⚠️ 上限 5 是**可读性**决定：ThemeMenu 本身不限项数（内部可滚），
     * 但一屏塞十几个分组名没有"挑选"的意义，想批量走
     * 「移入分组」页的入口（见 `openGroupPickerForTarget`）。
     */
    const maxItems: number = 5;
    const shown: BookGroup[] = groups.slice(0, maxItems);

    const labels: string[] = [];
    const ids: number[] = [];
    let currentIndex: number = -1;
    for (const group of shown) {
      const isCurrent: boolean = book.groupId === group.id;
      labels.push(isCurrent ? `${group.name}（当前）` : group.name);
      ids.push(group.id);
      if (isCurrent) {
        currentIndex = ids.length - 1;
      }
    }

    const truncated: boolean = groups.length > shown.length;
    const title: string = truncated
      ? `${book.title}（分组较多，仅显示前 ${shown.length} 个）`
      : book.title;

    this.openThemeMenu(title, labels, '', currentIndex, (index: number) => {
      const groupId: number = ids[index];
      if (groupId === undefined) {
        return;
      }
      /**
       * ⚠️ 选了"当前所在的分组"就直接返回，不做无意义的写库 + 刷新：
       * 那会闪一下列表，用户还以为发生了什么。
       */
      if (groupId === book.groupId) {
        return;
      }
      this.vm.moveToGroup(book.id, groupId).then(() => {
        this.toast('已移入分组');
      }).catch(() => {
        this.toast('移动失败');
      });
    });
  }

  /**
   * 打开「批量加入分组」页：**从已导入的书里勾选**，一次放进某个分组。
   *
   * ⚠️ 与 `showGroupPicker`（单本）的分工：
   *  - 单本 → 长按某本书，把它放进某个组；
   *  - 批量 → 从分组那一行进入，一次给一个组挑很多本书。
   * 两条路都需要：前者是日常整理，后者是"新建了一个组，把相关的书一次放进去"。
   */
  private openGroupPickerForTarget(groupId: number, groupName: string): void {
    const param: RouteParam = new RouteParam();
    param.groupId = groupId;
    /**
     * ⚠️ 名字随路由一起传（见 `RouteParam.groupName` 的说明）：
     * 目标页自己去查是异步的，首帧会先用默认值渲染标题，
     * 而普通成员赋值不触发重绘 —— 标题就永远停在错的名字上。
     */
    param.groupName = groupName;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.GROUP_PICKER_PAGE, params: param })
      .catch(() => {
        this.toast(`打开书籍选择页失败（目标：${groupName}）`);
      });
  }

  /**
   * 换编码重新解析。
   *
   * 正文乱码时的自救手段：自动探测不可能对每个 TXT 都准确，
   * 与其让用户重新导入，不如让他手动指定编码后重建章节。
   *
   * ⚠️ **必须二次确认**：重新分章会因外键 `ON DELETE CASCADE` 连带删除该书
   * 全部书签/笔记，而这是**不可撤销**的。早期只在菜单标题里写一行提示就直接执行
   * （设计文档 §P1 明确要求"书签功能上线后必须补确认弹窗"）—— 书签已经上线，
   * 所以这里补上。标题里的提示不算确认：用户点编码时视线在选项上，
   * 一行小字很容易被忽略，而代价是丢掉全部标注。
   *
   * 流程：选编码 → （有标注时）确认删除 → 执行。
   * 没有标注时不弹确认：此时没有可丢的东西，多一次点击只是打扰。
   */
  private async showEncodingPicker(book: Book): Promise<void> {
    const current: string = await this.vm.currentEncoding(book.id);
    const impacted: number = await this.vm.annotationsImpacted(book.id);

    const options: string[] = [
      Encodings.UTF8, Encodings.GB18030, Encodings.GBK,
      Encodings.BIG5, Encodings.UTF16LE, Encodings.UTF16BE
    ];
    const labels: string[] = [];
    let currentIndex: number = -1;
    for (let i = 0; i < options.length; i++) {
      labels.push(options[i] === current ? `${options[i]}（当前）` : options[i]);
      if (options[i] === current) {
        currentIndex = i;
      }
    }

    const title: string = impacted > 0
      ? `${book.title}（重新分章会删除已有的 ${impacted} 条书签/笔记）`
      : `${book.title}（选择正确的编码后重新分章）`;

    /**
     * ⚠️ `openThemeMenu` 的 onPick 不支持 async 回调链，
     * 确认步骤拆到 `_afterEncodingPicked`：选编码 → （有标注时）确认 → 执行。
     */
    this.openThemeMenu(title, labels, '', currentIndex, (index: number) => {
      /**
       * ⚠️ 下标必须**显式校验**，不能只靠"取出来是 undefined 再判断"。
       *
       * 选项数组长度与渲染项数并不保证一致；
       * 早先的写法把越界值继续往下传，最终会走到
       * `new util.StringDecoder(undefined)` 抛异常 —— 直接白屏。
       *
       * 判据：**外部输入的下标，使用前一律做边界检查**。
       */
      if (index < 0 || index >= options.length) {
        return;
      }
      const picked: string = options[index];
      if (picked === undefined || picked === current) {
        return;
      }
      this.afterEncodingPicked(book, current, picked, impacted);
    });
  }

  /** 编码已选定 → （有标注时）二次确认 → 执行重解析（从 showEncodingPicker 拆出） */
  private afterEncodingPicked(book: Book, current: string, picked: string, impacted: number): void {
    /**
     * ⚠️ 确认放在"选完编码之后"，不是点菜单时：
     * 用户此时才真的决定要重解析，而且能看到自己选了哪个编码。
     */
    if (impacted > 0) {
      this.openThemeConfirm('确认重新分章？',
        `这本书的 ${impacted} 条书签/笔记会一并被删除，且无法恢复。`,
        '删除并重新分章', true, () => {
          this.runReparse(book, picked);
        });
      return;
    }
    this.runReparse(book, picked);
  }

  /** 真正执行重解析（确认通过后调用） */
  private runReparse(book: Book, picked: string): void {
    this.toast(`正在按 ${picked} 重新解析…`);
    this.vm.reparseWithEncoding(book.id, picked).then((ok: boolean) => {
      if (ok) {
        /**
         * ⚠️ 重解析成功不代表编码选对了：若章数依然极少，说明这个编码也不对，
         * 必须**明确告警**而不是轻描淡写地说"完成" ——
         * 用户会立刻点进阅读页，而那本书的单章过大、会白屏假死。
         * 告警只弹一次（读后即清），避免每次刷新书架都重复打扰。
         */
        if (this.state.reparseSuspicious) {
          this.state.reparseSuspicious = false;
          this.toast(`按 ${picked} 只解析出很少的章节，编码可能仍不正确，建议再换一个编码试试`);
        } else {
          this.toast('重新解析完成，进阅读页确认');
        }
      } else {
        this.toast(this.state.error.length > 0 ? this.state.error : '重新解析失败');
        this.vm.clearError();
      }
    }).catch(() => {
      this.toast('重新解析失败');
    });
  }

  /**
   * 二次确认：重解析会删掉 N 条书签/笔记。
   *
   * ⚠️ 用 `showDialog` 而不是 `showActionMenu`：菜单的语义是"从若干平级选项里挑一个"，
   * 而这里是**是非确认**，且必须给出"取消"这个明确的退路。
   * 按钮顺序按系统约定：第 0 个是 positiveButton（确认），第 1 个是 negativeButton（取消）。
   *
   * ⚠️ 危险动作放在**第二个按钮**（非默认位），且用 `danger` 色：
   * 避免用户习惯性地按第一个按钮就把标注删了。
   *
   * @returns 用户是否确认继续
   */
  // ⚠️ confirmAnnotationLoss 已删除：二次确认改走 `openThemeConfirm`
  // （见 afterEncodingPicked），危险按钮与文案由 ThemeConfirm 统一承担。

  private openReader(book: Book): void {
    const param: RouteParam = new RouteParam();
    param.bookId = book.id;
    param.from = RouteName.BOOK_SHELF;
    // 用 @Entry 页面 + Router：ReaderPage 已登记在 resources/base/profile/main_pages.json。
    // 这样不依赖在非 @Entry 文件里 import 另一个 @Entry 页面（ArkTS 不允许）。
    // ⚠️ 走 UIContext 上的 Router，不用已废弃的 @ohos.router 全局函数。
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.READER_PAGE, params: param })
      .catch(() => {
        this.toast('打开阅读页失败');
      });
  }

  /** 打开书籍详情页（长按菜单「书籍详情」） */
  private openBookDetail(book: Book): void {
    const param: RouteParam = new RouteParam();
    param.bookId = book.id;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.BOOK_DETAIL_PAGE, params: param })
      .catch(() => {
        this.toast('打开书籍详情失败');
      });
  }

  // ------------------------------------------------------------ 分组管理

  /**
   * 长按分组条目 → 分组操作菜单。
   *
   * ⚠️ 它与分组详情页右上角的「更多」菜单**职责不同，都要保留**：
   *  - 本菜单（首页长按）= 不进入分组就能做的快捷操作；
   *  - 详情页的「更多」= 打开分组后的操作，多一项「编辑分组」（管理组内书籍）。
   *
   * ⚠️ 首页这里**不放「编辑分组」**：那是"管理组内的书"，
   * 而此刻用户还没打开这个组、看不到里面有什么 —— 让他先进去再编辑更合理。
   *
   * ⚠️ 文案与下标由同一个数组推导（设计文档第 28 条）。
   */
  private showGroupActions(groupId: number, name: string): void {
    const actions: string[] = ['打开分组', '加入书籍', '重命名', '解散分组'];

    this.openThemeMenu(`分组「${name}」`, actions, `${actions.length - 1}`, -1, (index: number) => {
      const picked: string = actions[index];
      if (picked === undefined) {
        return;
      }
      if (picked === '打开分组') {
        this.openGroupDetailById(groupId, name);
      } else if (picked === '加入书籍') {
        this.openGroupPickerForTarget(groupId, name);
      } else if (picked === '重命名') {
        this.openRenameGroupDialog(groupId, name);
      } else if (picked === '解散分组') {
        this.confirmDeleteGroup(groupId, name);
      }
    });
  }

  /**
   * 按 id 打开分组详情（长按菜单用）。
   *
   * ⚠️ 与 `openGroupDetail(group)` 是同一个动作的两个入口：
   * 一个手上是 `BookGroup` 对象、一个只有 id 与名字。
   * 不合并是因为详情页只需要 id + 名字两个值，
   * 为它去查一次 `BookGroup` 是多余的 IO。
   */
  private openGroupDetailById(groupId: number, name: string): void {
    const param: RouteParam = new RouteParam();
    param.groupId = groupId;
    param.groupName = name;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.GROUP_DETAIL_PAGE, params: param })
      .catch(() => {
        this.toast('打开分组失败');
      });
  }

  private openCreateGroupDialog(): void {
    this.editingGroupId = -1;
    this.editingGroupName = '';
    this.groupDialogVisible = true;
  }

  private openRenameGroupDialog(groupId: number, name: string): void {
    this.editingGroupId = groupId;
    this.editingGroupName = name;
    this.groupDialogVisible = true;
  }

  /**
   * 弹窗确认：新建或重命名（由 `editingGroupId` 决定走哪条路）。
   *
   * ⚠️ 两条路都**必须检查返回值**并给出反馈：
   * 重名是用户最容易犯的错（"我已经建过一个了"），静默失败会让他以为没生效。
   */
  private async submitGroupDialog(name: string): Promise<void> {
    this.groupDialogVisible = false;
    if (this.editingGroupId < 0) {
      const newId: number = await this.vm.createGroup(name);
      if (newId > 0) {
        this.toast('分组已创建');
      } else if (this.state.error.length > 0) {
        this.toast(this.state.error);
        this.vm.clearError();
      }
      return;
    }
    const ok: boolean = await this.vm.renameGroup(this.editingGroupId, name);
    if (ok) {
      this.toast('已重命名');
    } else if (this.state.error.length > 0) {
      this.toast(this.state.error);
      this.vm.clearError();
    }
  }

  /**
   * 删除分组前的二次确认。
   *
   * ⚠️ 必须先查**组内书籍数**并写进提示：删除分组**不会删书**（成员会被置为
   * 未分组），但用户看到"删除分组"第一反应是"我的书会不会没了"。
   * 明确告诉他有几本书会被移出、书本身保留，他才敢点。
   */
  private async confirmDeleteGroup(groupId: number, name: string): Promise<void> {
    let count: number = 0;
    try {
      count = await this.vm.countInGroup(groupId);
    } catch (e) {
      // 查不到数量不该挡住删除：退化成不带数量的提示
      count = 0;
    }

    const message: string = count > 0
      ? `组内 ${count} 本书会移到「未分组」，书和阅读进度都不会丢。`
      : '这个分组是空的，删除后无法恢复。';

    this.openThemeConfirm(`删除分组「${name}」？`, message, '删除分组', true, () => {
      this.vm.deleteGroup(groupId).then((moved: number) => {
        if (moved >= 0) {
          this.toast(count > 0 ? `已删除分组，${moved} 本书移到未分组` : '分组已删除');
        } else {
          this.toast(this.state.error.length > 0 ? this.state.error : '删除分组失败');
          this.vm.clearError();
        }
      }).catch(() => {
        this.toast('删除分组失败');
      });
    });
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }
}
