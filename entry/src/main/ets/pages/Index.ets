import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { ShelfState } from '../viewmodels/ShelfState';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { BookShelfPage } from './BookShelfPage';
import { ProfilePage } from './ProfilePage';

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
   * 从阅读页返回、或 App 从后台回到前台时触发。
   * 这正是"阅读进度改了但书架不刷新"缺失的那个时机。
   */
  onPageShow(): void {
    ShelfRefreshRegistry.refresh();
  }

  build() {
    Tabs({ index: this.activeTab }) {
      TabContent() {
        BookShelfPage({ state: this.shelfState, vm: this.shelfVm })
      }
      .tabBar(this.tabBuilder('书架', 0))

      TabContent() {
        this.buildPlaceholder('统计', '阅读时长、天数、连续打卡将在下一轮接入')
      }
      .tabBar(this.tabBuilder('统计', 1))

      TabContent() {
        ProfilePage()
      }
      .tabBar(this.tabBuilder('我的', 2))
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
    .height('100%')
  }

  @Builder
  tabBuilder(label: string, index: number) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(this.activeTab === index ? AppColor.brand : AppColor.textHint)
        .fontWeight(this.activeTab === index ? FontWeight.Medium : FontWeight.Normal)
    }
    .width('100%')
    .height(48)
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
