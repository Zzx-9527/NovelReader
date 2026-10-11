import { AppTheme } from '../common/theme/AppTheme';
import { ShelfState } from '../viewmodels/ShelfState';
import { BookShelfPage } from './BookShelfPage';
import { ProfilePage } from './ProfilePage';

/**
 * 应用根页面：底部 Tabs（书架 / 统计 / 我的）。
 *
 * 路由方案：`@Entry` 页面 + `router`。阅读页等通过 `router.pushUrl` 进入，
 * 需要登记在 `resources/base/profile/main_pages.json`。
 *
 * 书架状态由根页面持有并传给子页面：Tabs 切换时子页面会销毁重建，
 * 状态若放在子页面里，每次切回来都会丢失（滚动位置、分组选择等）。
 */
@Entry
@Component
struct Index {
  /** 由根页面持有的书架状态 */
  @State shelfState: ShelfState = new ShelfState();
  @State activeTab: number = 0;

  build() {
    Tabs({ index: this.activeTab }) {
      TabContent() {
        BookShelfPage({ state: this.shelfState })
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
    .barBackgroundColor(AppTheme.BG_CARD)
    .scrollable(false)
    .onChange((index: number) => {
      this.activeTab = index;
    })
    .width('100%')
    .height('100%')
  }

  @Builder
  tabBuilder(label: string, index: number) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(this.activeTab === index ? AppTheme.PRIMARY : AppTheme.TEXT_HINT)
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
        .fontColor(AppTheme.TEXT_PRIMARY)
      Text(hint)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.TEXT_HINT)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(AppTheme.BG_PAGE)
  }
}
