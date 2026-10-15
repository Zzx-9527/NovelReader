import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { ShelfState } from '../viewmodels/ShelfState';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { BookShelfPage } from './BookShelfPage';
import { ProfilePage } from './ProfilePage';
import { StatsPage } from '../views/stats/StatsPage';

/**
 * 底部 Tab 的图标与文案，**下标与 Tabs 的 index 严格对应**。
 *
 * ⚠️ 抽成数组而不是给 `@Builder` 多传几个参数：设计文档第 15/41 条
 * —— 带参 `@Builder` 在同一处 `build()` 里被调多次时**参数会串位**。
 * 这里三个 Tab 各调一次，正是那个坑的高发场景；
 * 让 `tabBuilder` 只收**一个** index、其余从数组查，串位就无从发生。
 */
const TAB_LABELS: string[] = ['书架', '统计', '我的'];
const TAB_ICONS: Resource[] = [
  $r('app.media.bookshelf'),
  $r('app.media.stats'),
  $r('app.media.mine')
];

/**
 * 底部 Tab 图标边长（vp）。
 *
 * ⚠️ 与文字合计约 34vp，`TAB_BAR_HEIGHT`(48) 留出约 14vp 余量 ——
 * 再加图标尺寸时要一并核对，否则会把 Tab 栏顶高、挤掉内容区。
 */
const TAB_ICON_SIZE: number = 20;

/**
 * 应用根页面：底部 Tabs（书架 / 统计 / 我的）。
 *
 * 路由方案：`@Entry` 页面 + `UIContext.getRouter()`。
 * 阅读页等通过 `router.pushUrl` 进入，并登记在 `main_pages.json`。
 *
 * 为什么刷新由本页驱动：
 * `onPageShow` 只对 `@Entry` 页面触发，书架页是普通 `@Component` 拿不到它。
 * 而"从阅读页返回后进度条要同步"必须有一个可靠时机，所以：
 *   - 本页 `onPageShow`（从阅读页返回、App 回到前台）→ 刷新书架
 *   - Tabs 切回书架那一栏 → 刷新书架
 * 两者都通过 ShelfRefreshRegistry 调用书架 ViewModel。
 *
 * 为什么状态与 ViewModel 由本页持有：
 * 书架页的 UI 读 `state`、数据写 `vm.state` —— 两者必须是**同一个对象**，
 * 否则数据加载完了 UI 也不会更新（详见 BookShelfPage 注释）。
 * 放在 `@Entry` 页面上，切换 Tab 也不会重建，滚动位置与分组选择得以保留。
 */
@Entry
@Component
struct Index {
  /**
   * 书架状态与 ViewModel 归本页持有，再传给书架页。
   * `ShelfState` 标了 `@Observed`，配合子页面的 `@ObjectLink` 才能观察到内部字段变化。
   */
  @State shelfState: ShelfState = new ShelfState();
  private shelfVm: BookShelfViewModel = new BookShelfViewModel();
  /**
   * 当前选中页签。
   *
   * ⚠️ 它必须由**点击瞬间**就更新，不能只靠 `Tabs.onChange` —— 见 `tabBuilder` 的说明。
   */
  @State activeTab: number = 0;
  /**
   * 正在被按下的页签下标；-1 表示没有。
   *
   * ⚠️ 用来做**按压反馈**：自定义 `@Builder` tabBar 不像系统默认 tabBar
   * 自带按压效果，得自己维护这个状态。
   */
  @State pressedTab: number = -1;
  /**
   * 页签控制器。
   *
   * ⚠️ 为什么需要它：`Tabs` 的 `index` 只是**初始值**，改 `activeTab`
   * 并不会让 Tabs 真的翻页（它不是双向绑定）。想在点击瞬间就切换，
   * 必须显式调 `changeIndex()`。
   */
  private tabsController: TabsController = new TabsController();

  /**
   * 安全区高度（vp），由 `EntryAbility` 测好后放进 `AppStorage`。
   *
   * 整个 app 开了沉浸式全屏，页面铺满整屏（含状态栏与手势条区域），
   * 每个页面都得自己让出这段高度：
   *  - 顶部不让 → "书架"标题会被状态栏的时间/信号图标盖住；
   *  - 底部不让 → 底部 Tab 栏会与系统手势条叠在一起、点不灵。
   */
  @StorageProp('safeAreaTop') safeAreaTop: number = 0;
  @StorageProp('safeAreaBottom') safeAreaBottom: number = 0;

  /**
   * 从阅读页返回、或 App 从后台回到前台时触发。
   * 这正是"阅读进度改了但书架不刷新"缺失的那个时机。
   */
  onPageShow(): void {
    ShelfRefreshRegistry.refresh();
  }

  build() {
    /**
     * ⚠️ 外层再套一个 Column，是为了**底部安全区单独着色**。
     *
     * 沉浸式全屏后，屏幕最底下那一条（手势条区域）必须由页面自己填色。
     * 如果只是给 `Tabs` 加 `padding({bottom: safeAreaBottom})`，
     * 那一条显示的是**外层背景**（`bgPage`，浅灰）—— 而它紧挨着的是
     * **白色导航栏**，于是看起来像"导航栏没铺到底、下面多了一条灰边"。
     *
     * 正确做法：底部安全区用**与导航栏同色**（`bgCard`）的独立占位填满，
     * 视觉上导航栏就自然延伸到了屏幕最底边。
     */
    Column() {
      Tabs({ index: this.activeTab, controller: this.tabsController }) {
        TabContent() {
          BookShelfPage({ state: this.shelfState, vm: this.shelfVm })
        }
        .tabBar(this.tabBuilder(0))

        TabContent() {
          StatsPage()
        }
        .tabBar(this.tabBuilder(1))

        TabContent() {
          ProfilePage()
        }
        .tabBar(this.tabBuilder(2))
      }
      .barPosition(BarPosition.End)
      .barMode(BarMode.Fixed)
      .barBackgroundColor(AppColor.bgCard)
      .scrollable(false)
      .onChange((index: number) => {
        /**
         * ⚠️ 这里**只**做数据刷新，不再负责更新高亮。
         *
         * `onChange` 的触发时机是"页签切换**完成**后"（含切换动画），
         * 若高亮态等它来改，就会出现用户反馈的"图标颜色慢了一拍"——
         * 手指已经点下去了，颜色还停在旧页签上。
         *
         * 高亮现在由 `switchTab()` 在**点击瞬间**同步改掉，本回调只兜底：
         * 手势滑动等**不经过 tabBuilder 点击**的路径也可能改变页签，
         * 那时仍需把 `activeTab` 对齐（否则高亮会与实际页面不一致）。
         */
        if (this.activeTab !== index) {
          this.activeTab = index;
        }
        if (index === 0) {
          // 切回书架：重新取数据，保证进度、导入结果都是最新的
          ShelfRefreshRegistry.refresh();
        }
      })
      .width('100%')
      // 占满"减去底部安全区"的剩余空间（不能用 height('100%')，那会溢出）
      .layoutWeight(1)

      /**
       * 底部安全区占位：用**导航栏同色**填满，让导航栏视觉上延伸到底。
       * 高度为 0 时不渲染，避免多一个无意义节点。
       */
      if (this.safeAreaBottom > 0) {
        Row()
          .width('100%')
          .height(this.safeAreaBottom)
          .backgroundColor(AppColor.bgCard)
      }
    }
    .width('100%')
    .height('100%')
    // 顶部安全区（状态栏）显示页面底色即可 —— 它上方是书架页的标题区，同为 bgPage
    .padding({ top: this.safeAreaTop })
    .backgroundColor(AppColor.bgPage)
    /**
     * 让整页**铺满屏幕**（含状态栏与手势条区域）—— 沉浸式的基础。
     *
     * ⚠️ 必须配合上面的 `padding`/占位一起用，两者分工不同：
     *  - `expandSafeArea` 决定**绘制范围**（背景铺到屏幕最边缘）；
     *  - `padding`/占位决定**内容范围**（内容不钻到状态栏/手势条下面）。
     * 只写前者 → 内容被系统元素盖住；只写后者 → 让出的那两条露出系统色。
     */
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 点击页签：**立刻**切换高亮与页面，不等 `Tabs.onChange`。
   *
   * ⚠️ 两条路径都要走（缺一不可）：
   *  1. 改 `activeTab` → 高亮色**同步**变（这是"慢一拍"的修复点）；
   *  2. 调 `changeIndex()` → 让 `Tabs` 真的翻页。
   * 只改 `activeTab` 不会翻页（`index` 不是双向绑定），
   * 只调 `changeIndex()` 则高亮要等 `onChange` 回来才变 —— 又慢一拍。
   */
  private switchTab(index: number): void {
    if (this.activeTab === index) {
      return;
    }
    this.activeTab = index;
    this.tabsController.changeIndex(index);
    /**
     * ⚠️ 这里**不**再调 `ShelfRefreshRegistry.refresh()`：
     * 页签真的切过去之后 `onChange` 必然触发，刷新由它统一负责。
     * 两处都调会让书架 `reloadData()` 跑两遍（闪一下、白做一次查询）。
     */
  }

  /**
   * 底部 Tab：图标 + 文字，选中态用**点缀色**。
   *
   * ⚠️ **只接收一个 `index`**，文案与图标都从顶部数组查 ——
   * 带参 `@Builder` 在同一处 `build()` 里调多次会串位（设计文档第 15/41 条），
   * 而这里恰好要调三次。把"每次不同的东西"收进数组按下标取，
   * 参数就只有 index 一个，串位无从发生。
   *
   * ⚠️ 图标用 `fillColor` 染色跟随选中态。三个 SVG 里 `mine.svg` 不带 `fill`、
   * 另两个带写死的 `fill`（如 `#303133`），但**都不影响染色** ——
   * 官方文档明确 `fillColor` 会"替换 svg 图片中所有可绘制元素"的填充色。
   * 所以换图标时不必检查 `fill` 属性。
   *
   * ⚠️ 本 `@Builder` 承担了系统默认 tabBar 的两件事：**按压反馈**与
   * **点击瞬间的高亮**。自定义 tabBar 不会自动获得这两者，见下方实现处注释。
   */
  @Builder
  tabBuilder(index: number) {
    Column() {
      /**
       * ⚠️ 栏顶发丝线：**三块各画一段，拼成整栏的一条**。
       *
       * 为什么不直接给 `Tabs` 的 bar 加边框：`Tabs` 的 `barBackgroundColor`
       * 只能设底色，系统 bar 内部没有暴露边框入口；而把线放在 `Tabs`
       * **外面**（与 bar 同级）又做不到 —— bar 是 `Tabs` 自己布局的。
       * 画在每个 tabBuilder 顶部是唯一能贴住栏顶的做法，
       * 代价是它参与 tab 的高度计算（所以下面的内容区必须用 `layoutWeight`）。
       *
       * ⚠️ 存在的理由：原实现的导航栏与页面底色（`bgPage` #FAFAFA）之间
       * 只靠 `bgCard`(#FFFFFF) 的 2% 明度差区分，在浅色下几乎看不出"这里
       * 开始是另一层"，深色下（#1A1A1A / #242424）更糊。一条发丝线
       * 一句话说清"导航栏到这里为止"，而它只花 1vp。
       */
      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)

      /**
       * 选中短横的**固定槽位**（4vp）。
       *
       * ⚠️ 槽位必须恒定存在、只有内容按选中态显隐 —— 若把整个 `Row` 放进
       * `if` 里，切换页签时栏内容会整体上下跳 4vp（这正是设计文档里
       * "高度随条件变化"那一类坑）。空槽位不画任何东西，但占住高度。
       *
       * ⚠️ 有了这条短横，选中态就有了**形状**上的标记，不再只靠颜色 ——
       * 对色觉障碍用户，颜色是唯一线索的界面是读不出选中项的。
       * 颜色（accent）与形状（短横）同时表达同一个状态，是冗余编码。
       */
      Row() {
        if (this.activeTab === index) {
          Row()
            .width(AppTheme.TAB_MARK_W)
            .height(AppTheme.TAB_MARK_H)
            .borderRadius(AppTheme.TAB_MARK_H / 2)
            .backgroundColor(AppColor.accent)
        }
      }
      .width('100%')
      .height(4)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      /**
       * 图标 + 文字。
       *
       * ⚠️ `layoutWeight(1)` 吃掉"栏高 − 发丝线 − 短横槽"的余量，
       * 再用 `justifyContent(Center)` 在余量里居中 ——
       * 于是上面那两行是**贴边**的，而图标文字仍是垂直居中的。
       */
      Column({ space: 2 }) {
        /**
         * ⚠️ 选中态用**点缀色**（`accent`）—— 这是主题色最主要的去处：
         * 面积小、位置固定（底部一栏），既能一眼看出在哪一页，又不会喧宾夺主。
         * 不要为了"更醒目"把它换成大色块（如给整个 Tab 加底色）。
         */
        Image(TAB_ICONS[index])
          .width(TAB_ICON_SIZE)
          .height(TAB_ICON_SIZE)
          .fillColor(this.activeTab === index ? AppColor.accent : AppColor.textHint)
          .objectFit(ImageFit.Contain)
          /**
           * ⚠️ 颜色变化加一段**短过渡**：用 `.animation()` 属性式动画，
           * 它作用于**它上方**的属性，所以颜色一改就自动补间，不需要手写 `animateTo`。
           *
           * 直接硬切会显得"闪"一下；这里 120ms 足够快、察觉不到延迟，
           * 又让图标与文字的颜色变化是"融"过去的。时长刻意远小于页签
           * 切换动画，避免重新引入"慢一拍"的观感。
           */
          .animation({ duration: 120, curve: Curve.EaseOut })

        Text(TAB_LABELS[index])
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.activeTab === index ? AppColor.accent : AppColor.textHint)
          .fontWeight(this.activeTab === index ? FontWeight.Medium : FontWeight.Normal)
          .animation({ duration: 120, curve: Curve.EaseOut })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(AppTheme.TAB_BAR_HEIGHT)
    /**
     * ⚠️ **按压反馈**：自定义 `@Builder` tabBar 不像系统默认 tabBar
     * 自带按压效果，必须自己实现 —— 否则用户点了"没有反应"，
     * 会怀疑是不是没点中（这正是本次反馈的问题之一）。
     *
     * 用 `pressedTab` 而不是每个 Tab 各存一个 `@State`：
     * tabBuilder 是**同一个** @Builder 被调三次，各自的状态无法区分，
     * 只能靠"当前按下的是哪一个下标"这个共享状态来表达。
     *
     * 反馈手段是**整块轻微缩放 + 变淡**：
     *  - 缩放用 0.92，肉眼可辨但不夸张；
     *  - 不透明度 0.6，保证未选中态（本来就是浅灰）也能看出被按下。
     * 之所以不换颜色：选中/未选中的颜色语义已经被"当前在哪一页"占用了，
     * 按压再用颜色会两者混淆。
     */
    .scale({ x: this.pressedTab === index ? 0.92 : 1, y: this.pressedTab === index ? 0.92 : 1 })
    .opacity(this.pressedTab === index ? 0.6 : 1)
    .animation({ duration: 90, curve: Curve.EaseOut })
    .onClick(() => {
      this.switchTab(index);
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressedTab = index;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedTab = -1;
      }
    })
  }

  /**
   * ⚠️ 已删除原 `buildPlaceholder`：统计页（StatsPage）已实装，
   * 第 2 个 Tab 不再是占位符。
   */
}
