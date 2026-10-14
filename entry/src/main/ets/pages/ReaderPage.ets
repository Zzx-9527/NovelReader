import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { ReaderState, BookmarkSaveResult, BookmarkDraft } from '../viewmodels/ReaderState';
import { ReaderViewModel } from '../viewmodels/ReaderViewModel';
import { ReaderJump, ReaderJumpRegistry } from '../viewmodels/ReaderJumpRegistry';
import { RouteName, RouteParam } from '../model/RouteParam';
import { AppTheme, ReaderTheme } from '../common/theme/AppTheme';
import { Logger } from '../common/utils/Logger';
import { AppConstants, LogTag } from '../common/constants/AppConstants';
import { LoadingView } from '../views/common/LoadingView';
import { ErrorView } from '../views/common/ErrorView';
import { ReaderTopBar } from '../views/reader/ReaderTopBar';
import { ReaderBottomBar } from '../views/reader/ReaderBottomBar';
import { SettingsPanel } from '../views/reader/SettingsPanel';
import { BookmarkDialog } from '../views/reader/BookmarkDialog';
import { ReaderSettings } from '../model/ReaderSettings';

/**
 * 阅读页（全屏，不显示底部 Tab）。
 *
 * 单击分区：左 1/3 上一页、右 1/3 下一页、中间呼出/隐藏菜单。
 */
@Entry
@Component
struct ReaderPage {
  @State state: ReaderState = new ReaderState();
  private vm: ReaderViewModel = new ReaderViewModel();
  /**
   * 顶部安全区（状态栏）高度，vp。由 `EntryAbility` 测好后放进 `AppStorage`。
   *
   * ⚠️ 整个 app 开了沉浸式全屏，页面会**铺满整屏**（含状态栏与手势条区域），
   * 所以每个页面都得自己让出这段高度 —— 否则正文第一行会钻到状态栏下面。
   * 用 `@StorageProp` 订阅：`EntryAbility` 测完写入后这里自动更新并重排，
   * 不需要自己处理"测量还没完成"的时序。
   *
   * ⚠️ 装饰器参数**刻意写字符串字面量**，不用 `AppStateKey.SAFE_AREA_TOP`：
   * `@StorageProp` 的参数会被 ets-loader 在**编译期**解析成 key 名，
   * 它对表达式形式的支持没有保证。字面量虽然与常量重复，但这是"装饰器必须"的重复，
   * 与 `AppStateKey` 里那句注释相互印证（改 key 时两处一起改）。
   */
  @StorageProp('safeAreaTop') safeAreaTop: number = 0;
  /** 底部安全区（手势条）高度，vp。用途同上 */
  @StorageProp('safeAreaBottom') safeAreaBottom: number = 0;
  /**
   * **应用级**主题当前是否为夜间。
   *
   * ⚠️ 与 `this.theme()`（阅读页正文背景）是两件事：
   * 本值只用来给菜单底栏的"夜间"入口上高亮，
   * 由 `ThemeApplier` 在施加主题后写入 `AppStorage`。
   *
   * ⚠️ 装饰器参数同样刻意写字面量（理由见 `safeAreaTop` 上方注释）。
   */
  @StorageProp('appDarkMode') appDarkMode: boolean = false;
  /**
   * 阅读区高度（第 1 层那个 Column），分页用。
   *
   * ⚠️ 量的必须是这个**高度恒定**的容器，而不是正文 Text 本身：
   * 分页模式下正文 Text 在本章第一页要给章节标题让位（高度少一截），
   * 若量它，翻到第二页尺寸又变回去 ⇒ 触发重新分页 ⇒ 页码归零 ⇒ 回到第一页 ⇒
   * **死循环**。恒定容器 + 把标题高度单独告诉分页服务，才是稳的。
   */
  private pageAreaHeight: number = 0;
  private contentWidth: number = 0;
  /**
   * scroll 模式：正文内容（章节标题 + 正文）的总高度。
   * 判断"这一章能不能滚""是否已滚到章末"用它。
   */
  private scrollContentHeight: number = 0;
  /**
   * 正文滚动容器。
   * 必须持有它才能拿到**绝对滚动偏移**（`currentOffset()`）——
   * `onScroll` 回调里的那个 offset 语义在不同 API 版本上并不一致，
   * 判断"是否滚到章末"这种事不能建立在它上面。
   */
  private scroller: Scroller = new Scroller();
  /** Scroll 自身高度（= 可视高度），与正文内容高度相减才能判断"能不能滚" */
  private viewportHeight: number = 0;
  /** 自动衔接的冷却截止时间戳，见 `AppConstants.AUTO_CONTINUE_COOLDOWN_MS` */
  private autoContinueBlockedUntil: number = 0;
  /**
   * 正文 `Text` 的控制器。
   *
   * ⚠️ 用来**主动关闭系统的选择菜单**（`closeSelectionMenu()`）：
   * 用户点了菜单里的任一项（复制/书签/搜索）后，菜单不会自己消失，
   * 必须我们显式关掉 —— 否则它一直悬在正文上挡住阅读。
   *
   * 分页模式与滚动模式各有一个 `Text`，但**同一时刻只会渲染其中一个**，
   * 所以共用一个 controller 是安全的（不会有两个实例同时挂上）。
   */
  private textController: TextController = new TextController();
  /**
   * 正文当前是否有选中的文字。
   *
   * ⚠️ **必须是普通成员，绝不能用 `@State`**（本项目实测踩过）。
   *
   * 它只用在**事件回调**里做判断（点击/滑动时决定"这次点击是取消选择还是翻页"），
   * **从不出现在 `build()` 里** —— 也就是说 UI 不依赖它，本来就不需要响应式。
   *
   * 而一旦标成 `@State`，`onTextSelectionChange` 每次触发都会改它
   * ⇒ 触发页面重新渲染 ⇒ **系统把选择菜单关掉**：
   * 表现就是"选中了文字、高亮和手柄都在，但菜单根本不显示"。
   *
   * **判据：字段只被事件回调读写、不参与 `build()` 时，一律用普通成员。**
   * `@State` 不是"能变就该加"，它买的是"变化要驱动 UI 重绘"，
   * 而重绘会打断系统组件的瞬时状态（菜单/弹窗/输入法）。
   */
  private hasSelection: boolean = false;
  /**
   * 当前选区的端点，用于 `Text.selection(start, end)`。
   *
   * ⚠️ 为什么需要它：`TextController` 只有 `closeSelectionMenu()`，
   * **没有**"清除选中高亮"的方法（SDK 里也没有 `TextSelectionManager`）。
   * 实测 `closeSelectionMenu()` 只关菜单，**高亮和手柄留在原地** ——
   * 用户反馈"菜单消失了但选中的没消失"。
   *
   * 解法：`Text.selection(start, end)`，文档明确"`start >= end` 时
   * 不选中任何文字"，所以设成 `(0, 0)` 就等于**程序化取消选中**。
   *
   * ⚠️ 关键设计：这两个值**始终如实反映当前选区**（由
   * `onTextSelectionChange` 同步），而不是只在取消时置零。
   * 因为 `selection` 是**构建期属性**，每次重绘都会重新施加 ——
   * 若平时传 `(-1, -1)` 或不传，重绘就会与用户的手势选择打架
   * （表现为"选不中"或"选区乱跳"）。如实回填则重绘无副作用：
   * 用户选到哪，属性就是哪。
   *
   * ⚠️ 必须是 `@State`：它参与 `build()`，改它才会重绘、`selection` 才生效。
   * 这与上面 `hasSelection`（普通成员、**不能**是 `@State`）正好相反，
   * 两者职责不同，别合并。
   */
  @State private selStart: number = 0;
  @State private selEnd: number = 0;
  /**
   * 本次触摸按下的时刻（`Date.now()`），用于区分"点击"与"长按"。
   *
   * ⚠️ 为什么必须区分：滚动模式的单击挂在 `parallelGesture(TapGesture)` 上，
   * 它的语义是"**可与子节点手势同时触发**" —— 长按选中正文后松手时，
   * 这个 Tap 也会触发，于是 `handleReaderTap` 看到有选中就去关菜单，
   * 表现是**选择菜单一闪就消失**（用户实测反馈：长按时菜单显示、一松手就没了）。
   *
   * 由 `onTouch` 在 `TouchType.Down` 时记录，在 `handleReaderTap` 里比对时长。
   */
  private touchDownAt: number = 0;
  /**
   * 加书签弹窗的草稿（章节名 / 选文 / 备注）。
   *
   * 放在**页面**而不是 ViewModel 的 state 里：它是"一次交互的临时数据"，
   * 不需要参与 `@Observed` 变更通知（弹窗靠 `bookmarkVisible` 开关重建）。
   */
  private bookmarkDraft: BookmarkDraft = new BookmarkDraft();

  aboutToAppear(): void {
    this.state = this.vm.state;
    /**
     * 注入"文字高度测量"函数，让分页走**实测**而不是估算。
     *
     * ⚠️ 四处关键点，都是查 SDK 声明与实测踩坑得来的：
     *
     * 1. **必须用 `UIContext.getMeasureUtils()`**，不用 `MeasureText.measureTextSize`
     *    —— 后者自 API 18 起已废弃（`@ohos.measure.d.ts:380` 的
     *    `@deprecated since 18` / `@useinstead ...MeasureUtils#measureTextSize`）。
     * 2. **返回单位是 px，而我们的宽高都是 vp**（`@ohos.arkui.UIContext.d.ts:2892`
     *    原文："The return values for text width and height are both in px"）。
     *    不换算就会差约 3 倍 —— 这正是之前"怎么调系数都不对"的根源。
     * 3. **在回调内部才取 utils**，不在 `aboutToAppear` 顶部取：
     *    `aboutToAppear` 阶段 UIContext 未必已完全就绪，
     *    而测量实际发生在之后的分页里，那时一定可用。
     * 4. 测量参数必须与渲染端 `Text` 的设置**逐项一致**
     *    （字号/行高/字距/字体），否则量出来的高度和实际渲染对不上。
     */
    this.vm.setMeasureFn((segment: string, width: number): number => {
      if (segment.length === 0) {
        return 0;
      }
      const s = this.state.settings;
      const size = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: segment,
        // 宽度按 vp 传入（number 即 vp），与渲染端 width('100%') 的可用宽度一致
        constraintWidth: width,
        fontSize: s.fontSize,
        lineHeight: s.fontSize * s.lineHeight,
        letterSpacing: s.letterSpacing,
        fontFamily: s.fontFamily,
        textIndent: 0
      });
      // px → vp：这一步不能省，否则高度会虚高约 3 倍
      return this.getUIContext().px2vp(Number(size.height));
    });
    // ⚠️ 用 UIContext 上的 Router，不用 @ohos.router 的全局函数 ——
    // 后者（pushUrl/replaceUrl/back/getParams）自 API 18 起全部废弃
    // （@ohos.router.d.ts:431/632/759 等），查询接口在
    // @ohos.arkui.UIContext.d.ts 的 class Router 上（getParams: :649）。
    const params = this.getUIContext().getRouter().getParams() as RouteParam | null;
    const bookId: number = params !== null && params !== undefined ? params.bookId : 0;
    if (bookId <= 0) {
      this.state.error = '缺少书籍参数，无法打开';
      this.state.loading = false;
      return;
    }
    this.vm.open(bookId).then(() => {
      this.tryPaginate();
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `打开阅读页失败: ${e.message}`);
    });
  }

  /**
   * 离开本页（跳去目录页、或 App 切后台）时立即结算阅读时长并落盘。
   *
   * ⚠️ 与 `aboutToDisappear` 的分工不同，两者都要留：
   *  - `onPageHide`：页面**还在栈里**（pushUrl 去目录页），此时不能 dispose
   *    （回来还要继续读），但要把进度结算落库 —— 否则用户在目录页时
   *    被系统回收，这一段阅读进度就丢了；
   *  - `aboutToDisappear`：页面**被销毁**（返回书架），必须 dispose 释放文件句柄。
   *
   * ⚠️ 调 `flush(true)` 而不是什么都不做，还解决了"计时穿帮"：
   * `ProgressService` 是按"上次结算时刻 → 现在"累计时长的，
   * 若离开时不停表，用户在目录页停留的几分钟会被算进**阅读时长**。
   * `flush` 内部会把计时起点重置到现在，等于在这里停了表。
   */
  onPageHide(): void {
    this.vm.onBackground().catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `离开阅读页落盘失败: ${e.message}`);
    });
  }

  aboutToDisappear(): void {
    // 必须释放：结算阅读时长 + 关闭文件句柄
    this.vm.close().then(() => {
      this.vm.dispose();
    }).catch(() => {
      this.vm.dispose();
    });
  }

  /**
   * 从目录页返回时触发：取出"待跳章"请求并执行。
   *
   * ⚠️ 为什么用 `onPageShow` + 登记表，而不是路由回传参数：
   * 见 `ReaderJumpRegistry` 的说明（`back(index, params)` 的下标脆弱，
   * `back({url, params})` 不承诺把 params 交给目标页）。
   *
   * ⚠️ `consume()` 是**取走即清空**的：`onPageShow` 也会在"App 从后台回来"
   * 时触发，若不清空，用户切个后台再回来就会莫名又跳一次。
   */
  onPageShow(): void {
    const jump: ReaderJump | null = ReaderJumpRegistry.consume();
    if (jump === null) {
      return;
    }
    // -1 表示"未指定偏移" → 落到章首。
    // ⚠️ 不能把 -1 直接传给 switchChapter：那里 -1 的含义是"定位到章末"。
    const toOffset: number = jump.offset < 0 ? 0 : jump.offset;
    this.vm.switchChapter(jump.chapterIndex, toOffset).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `跳章失败: ${e.message}`);
    });
  }

  /** 打开目录页（独立页面，push 进去；选章结果由 `ReaderJumpRegistry` 带回） */
  private openCatalog(): void {
    const param = new RouteParam();
    param.bookId = this.state.book !== null ? this.state.book.id : 0;
    // 传当前章进去，目录页打开时才能自动滚到当前位置
    param.chapterIndex = this.state.chapterIndex;
    this.getUIContext().getRouter().pushUrl({
      url: RouteName.READER_CATALOG_PAGE,
      params: param
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `打开目录页失败: ${e.message}`);
    });
  }

  /**
   * 顶栏"↻"：刷新当前阅读页。
   *
   * ⚠️ 必须 `.catch`：`refreshCurrentChapter` 内部已经把异常写进
   * `state.error`，但 Promise 本身若无人接住，异常会变成
   * "未处理的 Promise 拒绝"告警（设计文档第 26 条：
   * 不接 catch 的失败是完全静默的）。
   */
  private doRefresh(): void {
    this.vm.refreshCurrentChapter().then(() => {
      this.toast('已刷新');
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `刷新阅读页失败: ${e.message}`);
      this.toast('刷新失败');
    });
  }

  /** 统一 toast 入口（避免各处重复写 UIContext 取法） */
  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  /** 拿到正文区尺寸后才可能算分页；尺寸变化（旋转屏幕）也要重算 */
  private tryPaginate(): void {
    if (this.pageAreaHeight <= 0 || this.contentWidth <= 0) {
      return;
    }
    /**
     * ⚠️ 传给分页的宽度必须是**正文 Text 的内容宽度**，不是容器全宽。
     *
     * 正文 `Text` 带 `padding(pageMargin)`，它的内容宽度 =
     * 容器宽度 − 2×pageMargin。之前这里传的是容器全宽，而渲染是窄宽 ——
     * 于是 `measureTextSize` 按"更宽的可用宽度"量，得出的高度**偏小**，
     * 分页以为这页还能多放，实际却放不下（或反之），
     * 表现就是"有时顶部空一段、有时底部留白"这种忽隐忽现的错位。
     *
     * 分页、测量、渲染三处必须用同一个宽度，这是硬约束。
     */
    const bodyWidth: number = this.measureWidth();
    Logger.info(LogTag.READ,
      `分页尺寸: 容器w=${this.contentWidth.toFixed(1)} 正文w=${bodyWidth.toFixed(1)}`
        + ` h=${this.pageAreaHeight.toFixed(1)}`
        + ` 标题占位=${this.headingHeight().toFixed(1)}`
        + ` 字号=${this.state.settings.fontSize} 行距=${this.state.settings.lineHeight}`);
    this.vm.setContentSize(bodyWidth, this.pageAreaHeight, this.headingHeight());
    if (this.state.settings.pageMode !== 'scroll') {
      this.vm.loadChapter(this.state.chapterIndex);
    }
  }

  private theme(): ReaderTheme {
    /**
     * ⚠️ 必须把**全局夜间态**一起传进去：
     * 用户点菜单底栏的"夜间"是切整个 app，阅读页当然也要变深色 ——
     * 否则会出现"书架黑了、正文还是白的"这种割裂（用户明确要求全局一致）。
     *
     * 覆盖规则收在 `ReaderTheme.of` 一处，这里只负责把当前态递进去。
     */
    return ReaderTheme.of(this.state.settings.theme, this.appDarkMode);
  }

  /**
   * 常驻底栏占掉的**总高度**（vp）：固定高度 + 底部安全区。
   *
   * ⚠️ 全 app 沉浸式全屏后，底栏背景要一直铺到屏幕最底边（盖住手势条区域），
   * 但**文字不能压在手势条上** —— 所以文字区上方留出 `safeAreaBottom`。
   * 于是底栏总高 = `READER_FOOTER_HEIGHT` + `safeAreaBottom`。
   *
   * 这个值必须**同时**用于两处（否则菜单栏会压住常驻栏）：
   *   1. 底栏自身高度；
   *   2. 菜单栏整体上移的量。
   * 所以抽成一个方法，杜绝两处各写一份、改一处忘一处。
   */
  private footerTotalHeight(): number {
    return AppTheme.READER_FOOTER_HEIGHT + Math.max(0, this.safeAreaBottom);
  }

  build() {
    Stack() {
      // 第 1 层：正文 + **常驻底栏**（最底）。
      //
      // ⚠️ 常驻底栏放在**这一层内部**、与正文并列，而不是单独叠一层：
      // 这样正文区的 `layoutWeight(1)` 会自动得到"容器高度 − 底栏高度"，
      // 不需要手动扣减，也**绝不会被底栏挡住最后一行**。
      // 若把它做成 Stack 上的独立浮层，就必须自己保证"正文高度 = 总高 − 底栏高"，
      // 一旦漏算，分页每页都会少排一行，且极难联想到是底栏造成的。
      Column() {
        /**
         * ⚠️ 顶部安全区占位（状态栏那一条）。
         *
         * 整个 app 开了沉浸式全屏，页面铺满整屏（含状态栏区域）；
         * 不给这里留出高度，正文第一行就会钻到状态栏下面被时间/信号图标盖住。
         *
         * 用**显式占位**而不是给正文加 `padding.top`：占位是一个独立的兄弟节点，
         * 正文区的 `layoutWeight(1)` 拿到的是"扣掉它之后"的净高度，
         * `onAreaChange` 报出的也就是真正的可用高度 —— 分页不用做任何补偿。
         * 若用 padding，量到的高度会含 padding，分页会多算一行。
         *
         * 高度为 0 时不渲染，避免多一个无意义的节点。
         */
        if (this.safeAreaTop > 0) {
          Row()
            .width('100%')
            .height(this.safeAreaTop)
        }

        Column() {
          if (this.state.loading) {
            LoadingView({ message: '正在打开…' })
          } else if (this.state.error.length > 0) {
            ErrorView({
              message: this.state.error,
              hint: '可返回书架后重新导入这本书',
              actionText: '返回书架',
              onRetry: () => {
                this.goBack();
              }
            })
          } else {
            this.buildReaderBody()
          }
        }
        .width('100%')
        // 正文占满"减去底栏"的剩余空间（不能用 height('100%')，那会溢出）
        .layoutWeight(1)
        // 量出分页可用的**恒定**高度（见 pageAreaHeight 的说明）
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.onPageAreaChange(newArea);
        })

        // 章节变化时才变的常驻信息条：左=章节名，右=全书进度
        //
        // ⚠️ **无条件渲染**，不要加 `if (error.length === 0)` 之类的条件。
        // 它的显隐会改变正文区高度 ⇒ 触发 `onAreaChange` ⇒ 重新分页 ⇒
        // 而重新分页又会经过 loading/error 状态，可能再次改变显隐 ——
        // 正是设计文档第 39 条那类"高度随条件变化导致分页抖动"的坑。
        // 恒定显示换来高度恒定，代价只是出错时这里显示上一次的章节名。
        this.buildReaderFooter()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme().bg)

      // 第 2 层：翻页层（点击分区 + 左右滑动）。
      // ⚠️ 两条约束，缺一不可：
      //
      //  1. 只在"菜单隐藏时"存在 —— 否则它会覆盖在顶栏/底栏之上把点击截走，
      //     导致菜单弹出后无法收回（点中间等于又切换一次）。
      //
      //  2. **滚动模式绝不能有这一层** —— 这三个 Column 都绑了 onClick，
      //     按 ArkUI 的触摸测试规则（HitTestMode.Default：自身响应 + 阻塞兄弟节点），
      //     它们会把拖拽事件整个吃掉，下层 `Scroll` 永远收不到滑动。
      //     实测表现就是"阅读页划不动、只能点"。
      //     滚动模式下的点击交给 Scroll 自己接管（见 buildReaderBody）。
      if (!this.state.menuVisible && !this.state.settingsVisible
        && this.state.error.length === 0 && !this.state.loading
        && this.state.settings.pageMode !== 'scroll') {
        this.buildPageControls()
      }

      // 第 3 层：顶栏 / 底栏（只在菜单显示时出现，且位于翻页层之上）
      if (this.state.menuVisible && this.state.error.length === 0) {
        Column() {
          ReaderTopBar({
            /**
             * ⚠️ 顶栏中间显示**书名**，不是章节名（用户要求）。
             * 章节名由下面的常驻底栏承担，这里不再重复。
             * `state.book` 可能为 null（打开中），退回空串即可。
             */
            title: this.state.book !== null ? this.state.book.title : '',
            theme: this.theme(),
            onBack: () => {
              this.goBack();
            },
            onRefresh: () => {
              this.doRefresh();
            }
          })
          /**
           * 顶栏从**屏幕上方**滑下（`y` 为负 = 向上偏移，故起始位置在屏幕外）。
           * 动画挂在栏自己身上，而不是外层 Column —— 否则顶栏会跟着底栏
           * 一起从下往上滑，方向完全不对。
           */
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: -AppTheme.TOP_BAR_HEIGHT }).combine(TransitionEffect.opacity(0)),
            TransitionEffect.translate({ y: -AppTheme.TOP_BAR_HEIGHT }).combine(TransitionEffect.opacity(0))
          ).animation({ duration: 180, curve: Curve.FastOutSlowIn }))

          // 菜单显示时，点中间空白处收回菜单。
          // 分页模式下翻页层此时**不存在**（两块区域互斥渲染），没有这个点击点，
          // 用户就只能靠"返回"关菜单 —— 这是"菜单弹出来收不回去"的另一半。
          // 用 hideMenu() 而不是 toggleMenu()：收起是幂等的，
          // 不存在"连点两下又打开了"的抖动。
          Blank()
            .onClick(() => {
              this.vm.hideMenu();
            })

          ReaderBottomBar({
            theme: this.theme(),
            percent: this.state.percent,
            hasPrev: this.state.hasPrev,
            hasNext: this.state.hasNext,
            // 底部安全区高度：菜单栏要自己把这段也涂上色，
            // 否则它下方会露出常驻底栏或页面底色
            safeAreaBottom: this.safeAreaBottom,
            // 应用级夜间态：只影响"夜间"入口的高亮，
            // 与正文背景（this.theme()）是两回事
            appDarkMode: this.appDarkMode,
            onJump: (percent: number) => {
              this.vm.jumpToChapterByPercent(percent);
            },
            // 上一章回到"上一章的最后一页"（switchChapter 内部处理），
            // 符合"往回翻"的直觉
            onPrevChapter: () => {
              this.vm.prevChapter();
            },
            onNextChapter: () => {
              this.vm.nextChapter();
            },
            onOpenCatalog: () => {
              this.openCatalog();
            },
            onToggleNight: () => {
              /**
               * 切换**整个 app** 的深浅色 —— 不是阅读页正文背景
               * （那是"设置"里的主题，两者互不相干）。
               */
              if (!this.vm.toggleAppTheme()) {
                this.toast('切换夜间模式失败');
              }
            },
            onOpenSettings: () => {
              this.vm.setSettingsVisible(true);
            }
          })
          /**
           * 底栏从**屏幕下方**滑入：起始位置下移一个栏高（含安全区），
           * 视觉上就是"从底边升起、把常驻底栏盖住"。
           */
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: 80 }).combine(TransitionEffect.opacity(0)),
            TransitionEffect.translate({ y: 80 }).combine(TransitionEffect.opacity(0))
          ).animation({ duration: 180, curve: Curve.FastOutSlowIn }))
        }
        .width('100%')
        .height('100%')
        /**
         * ⚠️ 只让出**顶部**安全区；底部**不让位** —— 菜单栏要盖住常驻底栏。
         *
         * 这里是与早期实现的关键差别（用户实测反馈）：
         * 早期让菜单层整体上移 `footerTotalHeight()`，结果是两条栏**上下堆叠**，
         * 常驻底栏仍露在菜单下面，屏幕上同时出现两排信息、观感很乱。
         *
         * 正确行为是**覆盖**：菜单栏从屏幕底部升起，把常驻底栏整个盖住。
         * 于是这里不能有底部 padding，否则菜单栏就被顶到常驻栏上方了。
         * 底部安全区由 `ReaderBottomBar` 自己用 `safeAreaBottom` 涂满。
         *
         * ⚠️ 顶部仍必须让位，且必须写在**同一次** `padding()` 里：
         * ArkUI 里同一组件多次 `.padding()` 是后者覆盖前者、不是叠加。
         */
        .padding({ top: this.safeAreaTop })
      }

      // 第 4 层：设置面板。
      // 铺满全屏：下半部是面板本体，上半部是**透明的关闭热区** ——
      // 点空白处收起是浮层的通用预期，不给块遮罩是为了还能看见正文改了什么样。
      // 但没有透明热区又会"点面板以外毫无反应"，只能去点右上角"完成"。
      if (this.state.settingsVisible && this.state.error.length === 0) {
        Column() {
          // 上半部：空白热区，点了收起面板。
          // 给个最小高度，保证小屏上也不会被面板挤成 0 ——
          // 热区没了，用户就只能去点"完成"才能关面板。
          Column()
            .width('100%')
            .constraintSize({ minHeight: 56 })
            .layoutWeight(1)
            .onClick(() => {
              this.vm.setSettingsVisible(false);
            })

          SettingsPanel({
            settings: this.state.settings,
            theme: this.theme(),
            safeAreaBottom: this.safeAreaBottom,
            onChange: (next: ReaderSettings) => {
              // 就地生效：改完立刻重排，用户能直接看着正文调
              this.vm.updateSettings(next).catch((e: Object) => {
                Logger.error(LogTag.READ, `应用阅读设置失败: ${Logger.errText(e)}`);
              });
            },
            onClose: () => {
              this.vm.setSettingsVisible(false);
            }
          })
          // 面板最多占屏幕七成：留出热区，也让"改完能瞄一眼正文"
          .constraintSize({ maxHeight: '70%' })
          /**
           * 从底部滑入/滑出，与菜单底栏动作一致。
           *
           * ⚠️ 动画挂在**面板自身**，不挂外层 Column：外层还含"关闭热区"，
           * 一起位移会让热区在动画期间错位（顶部一截点不到）。
           * 热区是透明的，瞬间出现也看不出来，没必要参与动画。
           */
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: 80 }).combine(TransitionEffect.opacity(0)),
            TransitionEffect.translate({ y: 80 }).combine(TransitionEffect.opacity(0))
          ).animation({ duration: 180, curve: Curve.FastOutSlowIn }))
        }
        .width('100%')
        .height('100%')
        /**
         * ⚠️ **不让位**，与菜单底栏同理：设置面板从屏幕底部升起，
         * 要**盖住**常驻底栏，而不是叠在它上面。
         *
         * 早期写法是让出 `footerTotalHeight()`，结果面板底部停在常驻栏上沿，
         * 屏幕上同时出现"面板 + 常驻栏"两排信息 —— 与菜单底栏一样的观感问题。
         * 底部安全区改由 `SettingsPanel` 自己涂满。
         *
         * 顶部留出安全区，是为了让上面的关闭热区不被状态栏干扰。
         */
        .padding({ top: this.safeAreaTop })
      }

      // 第 5 层：加书签弹窗（最顶，压在设置面板之上）
      //
      // ⚠️ 放在**最后一层**：它由长按选中触发，可能发生在菜单已弹出时，
      // 必须保证它盖在最上面，否则会被设置面板/菜单挡住。
      //
      // ⚠️ **不给这层加 padding**：弹窗内部自带全屏遮罩
      // （`Stack` 铺满 + `AppColor.mask`），加了顶部让位反而会让遮罩
      // 盖不住状态栏、在最上面留出一条没被遮住的缝。
      // 卡片本身是**居中**的，本来也不与状态栏/手势条重叠。
      if (this.state.bookmarkVisible && this.state.error.length === 0) {
        BookmarkDialog({
          draft: this.bookmarkDraft,
          theme: this.theme(),
          onSave: (note: string) => {
            this.saveBookmark(note);
          },
          onCancel: () => {
            this.vm.setBookmarkVisible(false);
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    /**
     * 让整页**铺满屏幕**（含状态栏与手势条区域）—— 沉浸式的基础。
     *
     * ⚠️ 这里扩展 **TOP + BOTTOM 两边**，与本项目早期的写法不同：
     * 早期只敢扩展 BOTTOM，是因为当时内容会直接顶到边缘；
     * 现在**内容内缩已由显式占位负责**（顶部 `safeAreaTop` 占位、
     * 底部常驻栏含 `safeAreaBottom`），所以两边都可以放心扩展：
     * 背景色铺满全屏（沉浸式要的效果），而正文/文字仍落在安全区内。
     *
     * 前提是 `EntryAbility` 已开启窗口级全屏布局
     * （`setWindowLayoutFullScreen(true)`）—— 没有那一步，这里写什么都没用。
     */
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * **常驻底栏**：左=当前章节名，右=全书阅读进度。
   *
   * 与点击中间弹出的菜单底栏（`ReaderBottomBar`）是两回事：
   *  - 本栏**永远可见**，提供"我在哪一章、读了百分之多少"这两个随时想知道的信息；
   *  - 菜单底栏只在呼出菜单时出现，负责**操作**（进度条拖动、上下章、设置）。
   *    其中原本重复显示的章节名/百分比已经删掉 —— 常驻栏已经承担了。
   *
   * 章节名只在**换章**时变；百分比随翻页/滚动更新（它就是进度指示器）。
   *
   * ⚠️ 本栏**不绑任何手势**，也不做点击拦截：
   * 它只是"告知"，没有任何可交互元素。翻页层（第 2 层）铺满全屏、
   * 会盖住这条区域的触摸 —— 这是**有意为之**：用户点到屏幕最底部时
   * 期望的是翻页，而不是点到一个不可交互的信息条。
   *
   * 反过来说，正因为本栏不绑手势，它不会像早期那版点击分区那样
   * 把下层需要的拖拽吃掉（见设计文档第 37 条）。
   */
  @Builder
  buildReaderFooter() {
    /**
     * 底栏结构（自上而下）：
     * ```
     * ──────────── 分隔线
     * 章节名            5/16 97.1%   ← 文字区，固定 READER_FOOTER_HEIGHT
     * （safeAreaBottom 的空白，给手势条让位）
     * ```
     *
     * ⚠️ 高度必须**完全确定**（= `footerTotalHeight()`），因为菜单栏要按同一个值
     * 整体上移；靠内容撑开就会与它**对不上** ⇒ 菜单弹出时两栏重叠或留缝。
     *
     * 文字区用**固定高度**而不是 `layoutWeight`：后者会让文字行吃掉
     * 手势条那块空间，文字就压到手势条上了。
     * 于是下方自然空出 `safeAreaBottom` —— 背景色因此铺到屏幕最底边
     * （沉浸式要的效果），而文字仍落在手势条上方。
     */
    Column() {
      // 与正文的分隔线。
      // 用 `theme.secondary` 而非 `AppColor.divider`：本栏属于阅读页，
      // 配色必须跟随阅读主题（羊皮纸/夜间/护眼），
      // 用系统资源令牌会在这些主题下露出与正文不搭的系统色。
      Divider().color(this.theme().secondary)

      Row() {
        // 左：章节名。长标题截断，完整标题在目录里能看全
        Text(this.headingText())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme().secondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        /**
         * 右：**页码 + 全书进度**。
         *
         * 页码（如 `5/16`）只有分页模式才有值 —— scroll 模式整章连续滚动，
         * 没有"第几页"的概念，`pageText` 返回空串，这里就不渲染它，
         * 右侧只剩百分比。
         *
         * 两段都用 `GAP_S` 做左间距，靠右依次排列：`5/16  97.1%`。
         */
        if (this.state.pageText.length > 0) {
          Text(this.state.pageText)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(this.theme().secondary)
            .margin({ left: AppTheme.GAP_S })
        }

        Text(this.state.progressText)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme().secondary)
          .margin({ left: AppTheme.GAP_S })
      }
      .width('100%')
      /**
       * 文字行用 `layoutWeight(1)` 吃掉"总高 − 分隔线 − 手势条占位"的余量。
       *
       * ⚠️ 不要给它写固定 `height(READER_FOOTER_HEIGHT)`：那样
       * `分隔线 + 30 + safeAreaBottom` 会比总高多出分隔线那 1vp，产生溢出。
       * 用 `layoutWeight` 时，兄弟占位是**固定高度**，它拿到的正好是余量，不会多也不会少。
       */
      .layoutWeight(1)
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
      .alignItems(VerticalAlign.Center)

      /**
       * 手势条避让占位：把这块空间**显式**留出来。
       *
       * 用独立占位而不是让外层 `alignItems` 去挤：高度一眼可见，
       * 与 `footerTotalHeight()` 的构成（文字区 + 安全区）严格对应，
       * 以后改哪一部分都不容易算错。
       * 高度为 0 时不渲染，避免多一个无意义节点。
       */
      if (this.safeAreaBottom > 0) {
        Row()
          .width('100%')
          .height(this.safeAreaBottom)
      }
    }
    .width('100%')
    .height(this.footerTotalHeight())
    // ⚠️ 背景用**不透明**的 `theme.bg`，不用 `theme.barBg`：
    // `barBg` 是半透明色（alpha 约 F2），那是给"浮在正文之上的临时栏"用的
    // （顶栏/菜单底栏，让正文若隐若现）。本栏是**常驻**的，
    // 半透明会让正文文字从它后面透出来，看起来像渲染错误。
    .backgroundColor(this.theme().bg)
  }

  /**
   * 分页模式的翻页层：左 1/3 上一页、中 1/3 呼出菜单、右 1/3 下一页，
   * 左右滑动同样翻页（很多人第一反应就是滑，不该只有点击这一条路）。
   */
  @Builder
  buildPageControls() {
    Row() {
      Column()
        .width('33%')
        .height('100%')
        .onClick(() => {
          this.handleReaderTap('prev');
        })

      Column()
        .width('34%')
        .height('100%')
        .onClick(() => {
          this.handleReaderTap('menu');
        })

      Column()
        .width('33%')
        .height('100%')
        .onClick(() => {
          this.handleReaderTap('next');
        })
    }
    .width('100%')
    .height('100%')
    /**
     * ⚠️ 放行触摸（`HitTestMode.Transparent`），否则**长按选中正文不生效**。
     *
     * 本层铺满全屏且绑了 `onClick`，而 ArkUI 默认的 `HitTestMode.Default` 是
     * "自身响应 + **阻塞被它遮住的兄弟节点**" —— 下层正文 `Text` 收不到触摸，
     * 长按选不出文字、选择菜单也就永远不出现。
     * （与"阅读页划不动"是同一类坑：上层手势层把下层需要的触摸吃掉了。）
     *
     * `Transparent` 的语义正是"自身与子节点照常响应，**同时允许**被遮住的节点也参与命中"：
     * 三个分区的点击翻页照旧，正文也能收到长按。
     *
     * ⚠️ "选中后点别处会顺带翻页"这个问题，已由 `handleReaderTap` 解决
     * （有选中时第一次点击只取消选择），**不需要**再动这里的 hit test。
     */
    .hitTestBehavior(HitTestMode.Transparent)
    // 记录按下时刻：`handleReaderTap` 靠它区分"点击"与"长按"
    // （长按选中正文后松手时，三个分区的 onClick 也会触发）
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.touchDownAt = Date.now();
      }
    })
    // 手势挂在**整层**而不是三个分区上：一次滑动可能跨过两个分区，
    // 挂在父节点才能拿到完整位移。
    //
    // 用 PanGesture 的 offsetX 而不是 SwipeGesture 的 angle：
    // 位移的正负没有歧义（左滑为负），不必去记 angle 的角度约定。
    // 只认水平方向 —— 竖直滑动不属于翻页语义，让它落空即可。
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionEnd((event: GestureEvent) => {
          /**
           * ⚠️ 有选中文字时**不翻页**。
           *
           * 拖动选择手柄本身也是一次水平拖动，位移很容易超过翻页阈值 ——
           * 不拦的话，用户想扩大选区，结果翻了一页（与"点外面就翻页"同源）。
           * 这里直接让路：选择状态下滑动不翻页。
           */
          if (this.hasSelection) {
            return;
          }
          const dx: number = event.offsetX;
          if (dx <= -AppConstants.PAGE_SWIPE_MIN_DISTANCE) {
            this.vm.nextPage();
          } else if (dx >= AppConstants.PAGE_SWIPE_MIN_DISTANCE) {
            this.vm.prevPage();
          }
        })
    )
  }

  // ------------------------------------------------------------ 正文

  /**
   * 长按选中正文后的自定义菜单：在系统默认项（复制等）旁边加上**书签**。
   *
   * ⚠️ 书签入口为什么放在这里，而不是顶栏按钮：
   * 用户的心智是"选中一段 → 对这段做点什么（复制 / 书签）"，
   * 与系统复制同一个入口最自然；顶栏那个按钮已按反馈移除。
   *
   * ⚠️ 关键正确性：`range` 给的是**渲染文本（`renderedText`）的下标**，
   * 而书签必须存**原文偏移**（见 `ReaderViewModel.toOriginalOffset`）。
   * 两者差着"剥页首换行 + 段首缩进"这两步装饰，不换算就会存错位置。
   *
   * ⚠️ 这里返回的是普通对象，不是 `@Builder` —— `editMenuOptions` 要的是
   * `EditMenuOptions` 数据，不是 UI 构建器，别写成 `@Builder`。
   */
  private buildTextEditMenu(): EditMenuOptions {
    const bookmarkId: TextMenuItemId = TextMenuItemId.of('reader_bookmark');
    /**
     * ⚠️ 先声明成**带类型的局部变量**再返回，不直接 `return { ... }`：
     * ArkTS 的 `arkts-no-untyped-obj-literals` 要求对象字面量有明确的目标类型，
     * 写成带注解的局部变量是最无歧义的形式。
     */
    const options: EditMenuOptions = {
      onCreateMenu: (menuItems: Array<TextMenuItem>): Array<TextMenuItem> => {
        const bookmark: TextMenuItem = {
          content: '书签',
          id: bookmarkId
        };
        /**
         * ⚠️ 书签放在**最前面**，不是追加到末尾。
         *
         * 系统菜单项较多，追加到末尾会被折进那个 `∨` 展开箭头里 ——
         * 用户实测反馈"看不到书签"。放到首位就始终可见。
         *
         * 代价是「复制」被挤到第二位。可接受：本 App 里"加书签"是这个
         * 菜单的**主要**用途（见 §5.5.2），复制是系统附带的通用能力。
         */
        const mine: Array<TextMenuItem> = [bookmark];

        /**
         * ⚠️ 过滤掉不需要的系统项，但**保留搜索**。
         *
         * 系统默认会给一堆项，其中翻译 / 分享 / AI 写作等要么跳到别的应用、
         * 要么弹系统面板，在阅读器里纯属干扰（用户明确要求**去掉翻译**）。
         * 而**搜索是用户要保留的** —— 它由系统提供（本项目没有自己的搜索页），
         * 用来查选中的词，是很实用的能力。
         *
         * 用"白名单保留"而不是"黑名单删除"：
         * 系统后续新增的项默认不会冒出来，行为更可控。
         *
         * ⚠️ 曾经漏掉 SEARCH 导致"搜索功能丢了"（用户实测反馈）——
         * 加白名单时务必逐项确认，别把要留的一起过滤掉。
         */
        const kept: Array<TextMenuItem> = [];
        for (const item of menuItems) {
          if (item.id.equals(TextMenuItemId.COPY)
            || item.id.equals(TextMenuItemId.SELECT_ALL)
            || item.id.equals(TextMenuItemId.SEARCH)) {
            kept.push(item);
          }
        }
        return mine.concat(kept);
      },
      onMenuItemClick: (menuItem: TextMenuItem, range: TextRange): boolean => {
        const start: number = range.start ?? 0;
        const end: number = range.end ?? start;

        /**
         * ⚠️ **点任何一项，第一件事就是彻底清掉选择状态**。
         *
         * 这是"系统菜单挡住书签弹窗"的**真正根因**（此前误判为时序问题）：
         * 正文 `Text` 上绑着 `.selection(this.selStart, this.selEnd)`，
         * 而这里原本只关菜单、把 `hasSelection` 置假，**没有清这两个端点**。
         * 于是弹窗打开触发重绘时，`selection()` 又把选区**重新施加回去**，
         * 系统菜单跟着重新出现 —— 加多少延迟都没用。
         *
         * `clearSelection()` 会把端点压成 `(0, 0)`
         * （文档：`start >= end` 即不选中任何文字），从根上断掉重绘复活选区的可能。
         */
        this.clearSelection();

        const id: TextMenuItemId = menuItem.id;
        const isBookmark: boolean = id.equals(bookmarkId);
        const isCopy: boolean = id.equals(TextMenuItemId.COPY);
        /**
         * 仍然保留一点延迟：系统菜单是在自己的后续帧里收起的，
         * 立刻弹窗会与它的收起动画抢时序。等 `READER_MENU_DISMISS_MS`
         * 让菜单收干净，弹窗再出现，层级与观感都正确。
         */
        setTimeout(() => {
          if (isBookmark) {
            this.openBookmarkDialog(start, end);
          } else if (isCopy) {
            this.copySelection(start, end);
          }
        }, AppConstants.READER_MENU_DISMISS_MS);

        /**
         * 返回值只决定"要不要让系统继续执行它的默认行为"：
         *  - 书签/复制是我们自己实现的 → `true` 消费掉；
         *  - 其余（全选等）交回系统 → `false`。
         */
        return isBookmark || isCopy;
      }
    };
    return options;
  }

  /**
   * 清掉当前选择：关闭系统菜单 + 清除选中高亮。
   *
   * ⚠️ 两步都要做，缺一不可：
   *  - `closeSelectionMenu()` 只关**菜单**，高亮与手柄会留在原地
   *    （用户实测"菜单消失了但选中的没消失"）；
   *  - 真正清除高亮要靠把 `Text.selection` 设成 `(0, 0)`
   *    （文档：`start >= end` 即不选中任何文字），
   *    而 `selection` 是构建期属性，所以用 `selectionEpoch` 自增触发一次重绘。
   */
  private clearSelection(): void {
    this.textController.closeSelectionMenu();
    this.hasSelection = false;
    // 把选区端点压成 (0, 0)：文档明确 start >= end 时"不选中任何文字"，
    // 配合 @State 触发的那次重绘，高亮与手柄才会真正消失
    this.selStart = 0;
    this.selEnd = 0;
  }

  /**
   * 阅读区点击的统一入口：**有选中文字时，第一次点击只用来取消选择**。
   *
   * ⚠️ 为什么需要它（用户实测反馈）：选中文字后点空白处，本意是"取消选择"，
   * 但点击会直接执行翻页/切菜单 —— 选择状态还留着，非常别扭。
   *
   * 为什么不用"透明蒙层"那种做法：蒙层铺满全屏后，
   *  - 用默认 `HitTestMode.Default` → 连**选择手柄的拖动**一起挡掉，
   *    用户没法调整选区；
   *  - 用 `Transparent` → 点击照样传到下层，等于没拦。
   * 所以改为在这里判断：**同样是"点外面就关掉"的效果，但不碰触摸层级**，
   * 手柄照常可用。
   *
   * @param action 无选中时该点击原本要做的动作
   */
  private handleReaderTap(action: string): void {
    /**
     * ⚠️ 先排除"长按"：长按选中正文后松手时，滚动模式的
     * `parallelGesture(TapGesture)` 也会触发（它的语义就是"可与子节点手势同时触发"），
     * 于是这一下会被误当成"点击空白处"，把刚弹出的选择菜单关掉 ——
     * 用户看到的就是"菜单一闪就消失"。
     *
     * 判据用按住时长：超过 `READER_TAP_MAX_MS` 就算长按，直接放行不处理。
     */
    const heldMs: number = Date.now() - this.touchDownAt;
    if (this.touchDownAt > 0 && heldMs > AppConstants.READER_TAP_MAX_MS) {
      return;
    }

    if (this.hasSelection) {
      this.clearSelection();
      return;
    }
    if (action === 'prev') {
      this.vm.prevPage();
    } else if (action === 'next') {
      this.vm.nextPage();
    } else {
      this.vm.toggleMenu();
    }
  }

  /**
   * 复制选中内容到系统剪贴板。
   *
   * ⚠️ 为什么要**自己写剪贴板**，而不是让系统菜单的"复制"自己干活：
   * 实测发现走系统默认行为时内容**没有真正进入剪贴板**
   * （用户反馈"复制了之后没有到剪切板中"）。
   * 既然我们已经拦下这次点击（返回 `true`），就顺手把剪贴板写对 ——
   * 这也是唯一能保证"所见即所复制"的做法。
   *
   * ⚠️ 复制的是**原文**内容（先换算成原文偏移再截取）：
   * 直接从 `renderedText` 截会带上装饰插入的全角缩进空格。
   */
  private copySelection(renderedStart: number, renderedEnd: number): void {
    const startOriginal: number = this.vm.toOriginalOffset(renderedStart);
    const endOriginal: number = this.vm.toOriginalOffset(renderedEnd);
    const text: string = this.vm.originalTextBetween(startOriginal, endOriginal);
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({ message: '已复制' });
    } catch (e) {
      Logger.error(LogTag.READ, `复制失败: ${Logger.errText(e as Object)}`);
      this.getUIContext().getPromptAction().showToast({ message: '复制失败' });
    }
  }

  /**
   * 打开加书签弹窗（长按选中 → 菜单「书签」）。
   *
   * ⚠️ 两个下标都是**渲染文本**坐标，必须各自换算成原文偏移：
   * 只换起点会得到一段"起点对、终点偏"的选文（终点越大偏得越多）。
   */
  private openBookmarkDialog(renderedStart: number, renderedEnd: number): void {
    const startOriginal: number = this.vm.toOriginalOffset(renderedStart);
    const endOriginal: number = this.vm.toOriginalOffset(renderedEnd);
    this.bookmarkDraft = this.vm.buildBookmarkDraft(startOriginal, endOriginal);
    this.vm.setBookmarkVisible(true);
  }

  /** 保存书签（弹窗点"保存"） */
  private saveBookmark(note: string): void {
    // 把用户填的备注并进草稿（草稿是深拷贝，这里改的是页面自己那份）
    this.bookmarkDraft.note = note;
    this.vm.saveBookmark(this.bookmarkDraft).then((result: BookmarkSaveResult) => {
      this.vm.setBookmarkVisible(false);
      if (!result.ok) {
        // ⚠️ 失败必须单独提示，否则用户以为存上了
        this.getUIContext().getPromptAction().showToast({ message: '书签保存失败' });
        return;
      }
      // 区分"新建"与"覆盖"：用户刚在同位置存过时，明确告诉他旧的那条被替换了
      this.getUIContext().getPromptAction().showToast({
        message: result.updated ? '已更新该书签' : '已添加书签'
      });
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `保存书签失败: ${e.message}`);
    });
  }

  /**
   * 页眉文案 = 当前章节标题。
   *
   * 直接用手里的 `chapter.title`，**不再拼一个 App 自己的序号**：
   * `ChapterParser` 只把"匹配章节标记的行"收作 title（`^第 x 章/节/回`、
   * `CHAPTER n`、`序章/楔子/番外`…），所以标题本身就带序号 ——
   * 再拼一次就成了"第 64 章 · 第一章 玄鉴"这种重复。
   * 只有标题为空时才退回序号，取法与目录抽屉保持一致。
   */
  private headingText(): string {
    if (this.state.chapterTitle.length > 0) {
      return this.state.chapterTitle;
    }
    const index: number = this.state.chapterIndex;
    if (index < 0 || index >= this.state.chapters.length) {
      return '';
    }
    return `第 ${this.state.chapters[index].displayNumber()} 章`;
  }

  /** 章节标题的行高（必须与 buildChapterHeading 里设置的一致） */
  private headingLineHeight(): number {
    return (this.state.settings.fontSize + AppTheme.SIZE_STEP) * this.state.settings.lineHeight;
  }

  /**
   * 章节标题占用的总高度（分页时首页要让位的量）。
   *
   * ⚠️ **刻意不依赖 `headingText()`**，只由排版参数决定。
   *
   * 原因：`headingText()` 依赖 `state.chapterTitle`，而它是**异步加载**的 ——
   * 首帧布局时 `chapterTitle` 还是空串，此时算出的占位是 0；等章节加载完
   * 再算就变成 `headingLineHeight() + GAP_S + GAP_M`（默认排版下是 50）。
   * 同一个章节于是产生两个 `hx`、落进**两份分页缓存**，
   * 谁先命中就用谁 —— 表现正是"同一章有时排满、有时只排几段"这种飘忽的 bug。
   *
   * 判据：**凡是会进 `layoutKey` 的量，都必须是稳定的排版参数，
   * 不能依赖任何异步加载的内容**。
   *
   * 代价：本章若真的没有标题（`headingText()` 返回空），首页会白让位一行。
   * 可接受 —— 换来分页结果可复现，而"章节没标题"极少见
   * （`ChapterParser` 兜底也会给个"第 N 章"）。
   */
  private headingHeight(): number {
    return this.headingLineHeight() + AppTheme.GAP_S + AppTheme.GAP_M;
  }

  /**
   * 章节标题：它是**正文的第一行**，不是常驻页眉 —— 读过就跟着滚走。
   *
   * 字号 = 正文 + `AppTheme.SIZE_STEP`，加粗：标题必须比正文更重，
   * 否则和正文混在一起就不成其为标题。用相对量而非固定字号，
   * 是为了用户把正文调大时层级不会反过来。
   *
   * ⚠️ 本 `@Builder` **自身不加左右内边距**，因为两处调用点的让位方式不同：
   *  - 滚动模式：外层 `Column` 已带 `pageMargin`，标题在里面天然对齐；
   *  - 分页模式：标题与正文 `Text` 是**兄弟节点**，所以由调用点套一层
   *    带 `pageMargin` 的 `Column` 补上。
   * 若把 padding 写在这里，滚动模式会**叠成两倍**。
   * 与正文的区别只有字号、字重和下面垫的那点空隙。
   *
   * 单行省略：章节名偶尔很长（"第 3 章 他在雨里站了整整一夜"），
   * 换行会挤掉正文，截断更划算 —— 完整标题在目录里能看全。
   */
  @Builder
  buildChapterHeading() {
    if (this.headingText().length > 0) {
      Text(this.headingText())
        .fontSize(this.state.settings.fontSize + AppTheme.SIZE_STEP)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme().text)
        // 显式给行高：高度要可预测，分页按 headingHeight() 扣它
        .lineHeight(this.headingLineHeight())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ top: AppTheme.GAP_S, bottom: AppTheme.GAP_M })
    }
  }

  @Builder
  buildReaderBody() {
    if (this.state.settings.pageMode === 'scroll') {
      // 滚动模式：标题 + 整章正文在一个可滚动容器里，标题跟着滚走
      Scroll(this.scroller) {
        Column() {
          this.buildChapterHeading()
          Text(this.state.renderedText, { controller: this.textController })
            .fontSize(this.state.settings.fontSize)
            .fontColor(this.theme().text)
            .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
            .letterSpacing(this.state.settings.letterSpacing)
            // 同 paged 模式：缩进一律由文本承担，`textIndent` 恒为 0。
            // 滚动模式的 `renderedText` 是整章，VM 在 `renderAt` 的
            // scroll 分支里也会走 `indentParagraphHeads`。
            .textIndent(0)
            .width('100%')
            // 与分页模式一致：允许长按选中，并在系统菜单里加"书签"
            .copyOption(CopyOptions.InApp)
            .editMenuOptions(this.buildTextEditMenu())
            // 选区端点：如实回填当前选区，取消时压成 (0,0)（见字段说明）
            .selection(this.selStart, this.selEnd)
            // 跟踪"是否有选中"：有选中时第一次点击只取消选择（见 handleReaderTap）
            .onTextSelectionChange((start: number, end: number) => {
              this.hasSelection = end > start;
              // ⚠️ 只在真正有选中时回填：`(0,0)` 是我们主动取消时设的，
              // 系统随后的回调若也报 (0,0) 再回填一次是无害的幂等操作
              this.selStart = start;
              this.selEnd = end;
            })
        }
        .width('100%')
        // ⚠️ 左右页边距必须**真的**加在渲染上，否则与分页算的宽度对不上：
        // 分页按"容器宽度 − 2×pageMargin"算每行字数，渲染却铺满全宽，
        // 结果每行实际能放更多字 ⇒ 每页末尾被裁掉几行。
        .padding({ left: this.state.settings.pageMargin, right: this.state.settings.pageMargin })
        // 量的是"标题 + 正文"的**内容总高度**：判断是否滚到章末时
        // 标题占的高度也算在内，否则会提前一行触发自动衔接
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.onScrollContentChange(newArea);
        })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      // 用 layoutWeight 而不是 height('100%')：百分比取的是**父容器**高度，
      // 一旦以后在正文之上再放常驻元素（页眉/工具栏），"元素 + 100%"就会溢出屏幕，
      // Scroll 底部一段永远滚不到。layoutWeight 取的是真正的剩余空间。
      .layoutWeight(1)
      // 量出可视高度：判断"这一章能不能滚""是否已滚到章末"都要它
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.viewportHeight = Number(newArea.height);
      })
      // 单击切菜单。
      //
      // ⚠️ 必须用 `parallelGesture(TapGesture)` 而**不是** `onClick`：
      // 正文 `Text` 设了 `copyOption`（可长按选中）后，它自己会参与触摸竞争，
      // 挂在父节点 `Scroll` 上的 `onClick` 会**收不到单击** ——
      // 表现就是"点中间打不开状态栏"（本项目实测踩过）。
      // `parallelGesture` 的语义是"与子节点手势**并行**识别"，
      // 因此正文照旧能长按选中，父节点也能收到单击。
      .parallelGesture(
        TapGesture()
          .onAction(() => {
            // 与分页模式一致：有选中时这一下只用来取消选择，不切菜单
            this.handleReaderTap('menu');
          })
      )
      // 记录按下时刻：`handleReaderTap` 靠它区分"点击"与"长按"
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.touchDownAt = Date.now();
        }
      })
      .onScroll((scrollOffset: number) => {
        this.onReaderScroll(scrollOffset);
      })
    } else {
      // 分页模式：标题只出现在本章第一页。首页让位的那一截高度
      // 已通过 setContentSize(..., headingHeight()) 交给分页服务扣除，
      // 所以这里直接渲染不会把首页最后一行挤掉。
      if (this.state.pageIndex === 0) {
        /**
         * ⚠️ **必须给标题补上和正文一样的左右边距**，否则它会顶到屏幕最左边
         * （用户反馈"顶格太丑"）。
         *
         * 原因：本模式下标题与正文 `Text` 是**并列的兄弟节点**，
         * 而左右 `pageMargin` 是加在正文 `Text` 自己身上的
         * （见下面 `.padding({ left: pageMargin, ... })`）——
         * 标题不在那个 `Text` 里，自然一点边距都没有。
         *
         * ⚠️ 只在**分页模式**这里补：滚动模式的标题在带 `pageMargin`
         * 的 `Column` 内部（见上面 scroll 分支），已经让过位了；
         * 若把 padding 写进 `buildChapterHeading` 本身，滚动模式会**叠成两倍**。
         *
         * ⚠️ 用 `Column` 包一层而不是给 `@Builder` 加参数：
         * 带参 `@Builder` 在同一处 `build()` 里被调多次会串位
         * （设计文档第 15/41 条），而 `buildChapterHeading` 在本文件有两处调用。
         *
         * ⚠️ 这层 `Column` 只有单个子节点、自身无 padding，
         * 高度与原来完全相同 —— 所以 `headingHeight()` 的算法不用改。
         */
        Column() {
          this.buildChapterHeading()
        }
        .width('100%')
        .padding({
          left: this.state.settings.pageMargin,
          right: this.state.settings.pageMargin
        })
      }
      // 翻页与呼出菜单由上层 buildPageControls 处理
      Text(this.state.renderedText, { controller: this.textController })
        .fontSize(this.state.settings.fontSize)
        .fontColor(this.theme().text)
        .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
        .letterSpacing(this.state.settings.letterSpacing)
        // ⚠️ `textIndent` **恒为 0**：段首缩进一律由 ViewModel 在
        // `renderedText` 里按行手工补（见 `indentParagraphHeads`）。
        // 原因是 `textIndent` 全局按 `\n` 生效，无法区分
        // "续行 / 原文自带缩进的段 / 真正的段首"这三种情况 ——
        // 交给它就会同时出现"续行被误缩进"和"缩进叠成 4 格"两个 bug。
        .textIndent(0)
        .width('100%')
        // 允许长按选中并复制（配合下面的自定义菜单加"书签"）
        .copyOption(CopyOptions.InApp)
        // 长按选中后的菜单：在系统"复制"旁边加上"书签"
        .editMenuOptions(this.buildTextEditMenu())
        // 选区端点：如实回填当前选区，取消时压成 (0,0)（见字段说明）
        .selection(this.selStart, this.selEnd)
        // 跟踪"是否有选中"：有选中时第一次点击只取消选择（见 handleReaderTap）
        .onTextSelectionChange((start: number, end: number) => {
          this.hasSelection = end > start;
          this.selStart = start;
          this.selEnd = end;
        })
        // 左右页边距：与分页里减掉的 `pageMargin * 2` 对应，两边必须同一个值
        .padding({ left: this.state.settings.pageMargin, right: this.state.settings.pageMargin })
        .align(Alignment.TopStart)
        // ⚠️ **不**用 layoutWeight 撑满。
        //
        // 曾经用 `layoutWeight(1)`，是为了让 onAreaChange 报出"确定的可用高度"
        // 好喂给分页。代价是它把两个量搞混了：
        //  - 分页需要的"可用高度" → 已经由第 1 层 Column 的 pageAreaHeight 提供；
        //  - 校验需要的"文字真实高度" → 一旦撑满就永远报容器高度，**测不到**。
        // 现在改成自适应内容：Text 高度 = 文字实际占的高度，
        // 与 pageAreaHeight 一比就能立刻判断"算法认为能放几行"和
        // "实际渲染了几行"是否一致（分页准不准的唯一判据）。
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.onPagedTextAreaChange(newArea);
        })
    }
  }

  /**
   * 分页/测量用的正文可用宽度（vp）。
   *
   * ⚠️ 必须与 `PaginationService.computeBreaksMeasured` 收到的
   * `contentWidth` **完全一致**，否则"测量"与"实际渲染"用的宽度不同，
   * 量出来的高度就不等于真实高度 —— 分页会因此算错每页装多少字。
   *
   * 这里已经扣掉了左右页边距：正文 `Text` 有 `padding(pageMargin)`，
   * 所以它的内容宽度 = 容器宽度 − 2×pageMargin。
   */
  private measureWidth(): number {
    return Math.max(1, this.contentWidth - this.state.settings.pageMargin * 2);
  }

  /**
   * 分页模式：正文 Text 的尺寸变化。
   *
   * 这条日志是**校验分页准不准的唯一判据**：
   * `Text` 现在高度自适应内容，所以报出的就是"这些文字实际占了多高"。
   * 把它除以行高得到**实测行数**，与分页算法假设的"每页行数"一比：
   *  - 实测行数 ≈ 假设行数 → 分页是准的；
   *  - 实测行数 < 假设行数 → 算法把行数算多了（切给这页的字太少）；
   *  - 实测行数 > 假设行数 → 算少了（会溢出、末行被裁）。
   */
  private onPagedTextAreaChange(area: Area): void {
    const height: number = Number(area.height);
    const text: string = this.state.renderedText;
    const lineHeight: number = Math.max(1,
      this.state.settings.fontSize * this.state.settings.lineHeight);
    const measuredLines: number = height / lineHeight;

    /**
     * ⚠️ **决定性自检**：把"分页用的测量函数算出的高度"
     * 与"`Text` 实际渲染出来的高度"直接对比。
     *
     * 这两个数必须几乎相等。若测量值明显小于实际值，说明
     * `measureTextSize` 的参数与渲染端 `Text` 的设置不一致
     * （或单位没换算对）—— 那正是"每页装不满、底部留白"的根源：
     * 分页以为这页已经放不下更多字，实际还剩很多空间。
     *
     * 用 `renderedText` 量而不是 `fullText` 的片段：要的就是
     * "这一页实际渲染的内容"对应的测量值，两者才可比。
     */
    let measureCheck: string = '未注入';
    if (this.vm.hasMeasureFn()) {
      const measured: number = this.vm.measureHeight(text, this.measureWidth());
      const diff: number = measured - height;
      measureCheck = `测量高=${measured.toFixed(1)} 差=${diff.toFixed(1)}`
        + `(${height > 0 ? ((diff / height) * 100).toFixed(1) : '0'}%)`;
    }

    // 数换行与空行：判断"物理行 vs 自然段"的关键证据
    let nlCount: number = 0;
    let blankCount: number = 0;
    for (let i = 0; i < text.length; i++) {
      if (text.charAt(i) !== '\n') {
        continue;
      }
      nlCount++;
      const next: number = i + 1;
      if (next < text.length && text.charAt(next) === '\n') {
        blankCount++;
      }
    }

    // 本页前 6 个物理行的**首字符码点**：用来核对"段首缩进"的实际情况。
    // 0x3000 = 全角空格。**注意这里是 `renderedText`（渲染副本），
    // 已经过 `indentParagraphHeads` 处理** —— 所以：
    //   - 真段首 → 应以 0x3000 开头（手工补的缩进）；
    //   - 续排页第一行 → 不应以 0x3000 开头（续行不缩进）；
    //   - 原文自带缩进的段 → 也是 0x3000，但只有一份（不会叠成 4 格）。
    // 若发现"真段首没有 0x3000"，说明手工补缩进没生效。
    const heads: string[] = [];
    let cursor: number = 0;
    let lineNo: number = 0;
    while (cursor <= text.length && lineNo < 6) {
      const nl: number = text.indexOf('\n', cursor);
      const lineEnd: number = nl < 0 ? text.length : nl;
      const line: string = text.substring(cursor, lineEnd);
      const code: string = line.length > 0 ? line.charCodeAt(0).toString(16) : '-';
      heads.push(`#${lineNo}:0x${code}(字${line.length})`);
      lineNo++;
      if (nl < 0) {
        break;
      }
      cursor = nl + 1;
    }

    Logger.info(LogTag.PAGINATION,
      `分页正文实测: 实高=${height.toFixed(1)} 行高=${lineHeight.toFixed(1)}`
        + ` 实测行数=${measuredLines.toFixed(1)}`
        + ` | 容器可用=${this.pageAreaHeight.toFixed(1)}`
        + ` 标题占位=${this.headingHeight().toFixed(1)}`
        + ` 本页字数=${text.length} 换行数=${nlCount} 空行段数=${blankCount}`
        + ` | 测量自检 ${measureCheck}`
        + ` | 行首码点 ${heads.join(' ')}`);
  }

  /**
   * 滚动模式的每帧回调：上报阅读进度 + 判断是否该无缝衔接下一章。
   */
  private onReaderScroll(scrollOffset: number): void {
    // 用滚动量估算当前字符偏移：行高与每行字数都由字号推出
    const lineHeight: number = Math.max(1,
      this.state.settings.fontSize * this.state.settings.lineHeight);
    const charsPerLine: number = Math.max(1,
      Math.floor(this.contentWidth / Math.max(1, this.state.settings.fontSize)));
    const lines: number = Math.floor(scrollOffset / lineHeight);
    this.vm.reportScrollOffset(lines * charsPerLine);

    if (this.shouldContinueToNextChapter()) {
      // 先上锁再切章：切章过程中还会到达若干次滚动回调，
      // 此时"到底了没"用的仍是旧内容的高度，不锁就会连跳好几章
      this.autoContinueBlockedUntil = Date.now() + AppConstants.AUTO_CONTINUE_COOLDOWN_MS;
      // 接住 Promise：不接的话衔接失败会被完全静默吞掉（设计文档第 26 条）
      this.continueToNextChapter().catch((e: Object) => {
        Logger.error(LogTag.READ, `章末自动衔接失败: ${Logger.errText(e)}`);
      });
    }
  }

  /** 是否已滚到章末，该自动衔接下一章了 */
  private shouldContinueToNextChapter(): boolean {
    if (Date.now() < this.autoContinueBlockedUntil
      || this.state.loading || !this.state.hasNext) {
      return false;
    }
    // ⚠️ 先判断"这一章到底能不能滚"：
    // 章节短到一屏放得下时 `scrollContentHeight <= viewportHeight`，
    // 滚动条本来就在底部 —— 少了这一句就会"短章无限自动连跳"直到全书末尾。
    if (this.viewportHeight <= 0 || this.scrollContentHeight <= this.viewportHeight + 1) {
      return false;
    }
    const y: number = this.scroller.currentOffset().yOffset;
    return y + this.viewportHeight >= this.scrollContentHeight - 2;
  }

  /**
   * 无缝衔接：静默加载下一章，并把正文滚回顶部。
   *
   * 滚回顶部这步不能省：内容换了但滚动位置还停在上一章的 max 处，
   * 新章会直接从末尾开始显示 —— 那就不是"衔接"而是"跳章"了。
   */
  private async continueToNextChapter(): Promise<void> {
    const switched: boolean = await this.vm.continueToNextChapter();
    if (switched) {
      this.scroller.scrollEdge(Edge.Top);
    }
  }

  /** 阅读区（第 1 层 Column）尺寸变化 → 重算分页 */
  private onPageAreaChange(area: Area): void {
    const width: number = Number(area.width);
    const height: number = Number(area.height);
    if (width <= 0 || height <= 0) {
      return;
    }
    // 与 Scroll 的实测高度对照打日志：两者应当接近（差一个标题高度）。
    // "每页字多字少/上下留白"这类问题几乎都出在这里，有日志就不用反复猜。
    Logger.info(LogTag.READ,
      `阅读区实测: w=${width.toFixed(1)} h=${height.toFixed(1)}`
        + ` | Scroll 视口=${this.viewportHeight.toFixed(1)}`);
    const changed: boolean = Math.abs(width - this.contentWidth) > 1
      || Math.abs(height - this.pageAreaHeight) > 1;
    this.contentWidth = width;
    this.pageAreaHeight = height;
    if (changed) {
      // 尺寸变化（旋转屏幕/改字号）需要重新分页
      this.tryPaginate();
    }
  }

  /** scroll 模式：正文内容总高度变化（含章节标题） */
  private onScrollContentChange(area: Area): void {
    const height: number = Number(area.height);
    if (height > 0) {
      this.scrollContentHeight = height;
    }
  }

  private goBack(): void {
    this.vm.close().then(() => {
      this.vm.dispose();
      this.back();
    }).catch(() => {
      this.vm.dispose();
      this.back();
    });
  }

  private back(): void {
    this.getUIContext().getRouter().back();
  }
}
