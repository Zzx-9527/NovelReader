import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { ShelfState } from '../viewmodels/ShelfState';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { BookShelfPage } from './BookShelfPage';
import { ProfilePage } from './ProfilePage';

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
  @State activeTab: number = 0;

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
      Tabs({ index: this.activeTab }) {
        TabContent() {
          BookShelfPage({ state: this.shelfState, vm: this.shelfVm })
        }
        .tabBar(this.tabBuilder(0))

        TabContent() {
          this.buildPlaceholder('统计', '阅读时长、天数、连续打卡将在下一轮接入')
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
        this.activeTab = index;
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
   * 底部 Tab：图标 + 文字，选中态用品牌色。
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
   */
  @Builder
  tabBuilder(index: number) {
    Column({ space: 2 }) {
      Image(TAB_ICONS[index])
        .width(TAB_ICON_SIZE)
        .height(TAB_ICON_SIZE)
        .fillColor(this.activeTab === index ? AppColor.brand : AppColor.textHint)
        .objectFit(ImageFit.Contain)

      Text(TAB_LABELS[index])
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(this.activeTab === index ? AppColor.brand : AppColor.textHint)
        .fontWeight(this.activeTab === index ? FontWeight.Medium : FontWeight.Normal)
    }
    .width('100%')
    .height(AppTheme.TAB_BAR_HEIGHT)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  buildPlaceholder(title: string, hint: string) {
    Column({ space: AppTheme.GAP_S }) {
      Text(title)
        .fontSize(AppTheme.FONT_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
      Text(hint)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.textHint)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(AppColor.bgPage)
  }
}
