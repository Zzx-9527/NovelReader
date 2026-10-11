import { promptAction, router } from '@kit.ArkUI';
import { AppTheme } from '../common/theme/AppTheme';
import { RouteName } from '../model/RouteParam';
import { PageCacheRepository } from '../data/repository/PageCacheRepository';

/** "我的"页：设置入口、缓存清理、关于 */
@Component
export struct ProfilePage {
  @State cacheCount: number = 0;
  @State clearing: boolean = false;

  aboutToAppear(): void {
    this.loadCacheInfo();
  }

  private async loadCacheInfo(): Promise<void> {
    try {
      this.cacheCount = await PageCacheRepository.countAll();
    } catch (e) {
      this.cacheCount = 0;
    }
  }

  build() {
    Column({ space: AppTheme.GAP_M }) {
      Text('我的')
        .fontSize(AppTheme.FONT_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppTheme.TEXT_PRIMARY)
        .width('100%')

      Column() {
        this.settingRow('阅读设置', '字号、行距、主题、翻页方式', () => {
          router.pushUrl({ url: RouteName.SETTINGS_PAGE }).catch(() => {
            promptAction.showToast({ message: '设置页尚未实现' });
          });
        })
        Divider().color(AppTheme.DIVIDER)

        this.settingRow('清除分页缓存', `当前 ${this.cacheCount} 条`, () => {
          this.clearCache();
        })
        Divider().color(AppTheme.DIVIDER)

        this.settingRow('自检页（开发用）', '验证数据库与解析链路', () => {
          router.pushUrl({ url: 'pages/SelfCheckPage' }).catch(() => {
            promptAction.showToast({ message: '未找到自检页' });
          });
        })      }
      .width('100%')
      .backgroundColor(AppTheme.BG_CARD)
      .borderRadius(AppTheme.CARD_RADIUS)

      Column({ space: 4 }) {
        Text('小说阅读器')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.TEXT_HINT)
        Text('本地导入 · 离线阅读 · 无广告 · 不上传任何内容')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.TEXT_HINT)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding(AppTheme.GAP_M)

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding(AppTheme.PAGE_PADDING)
    .backgroundColor(AppTheme.BG_PAGE)
  }

  @Builder
  settingRow(title: string, subtitle: string, onTap: () => void) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .width('100%')
        Text(subtitle)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.TEXT_HINT)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor(AppTheme.TEXT_HINT)
    }
    .width('100%')
    .padding(AppTheme.GAP_M)
    .onClick(onTap)
  }

  private async clearCache(): Promise<void> {
    if (this.clearing) {
      return;
    }
    this.clearing = true;
    try {
      await PageCacheRepository.clearAll();
      await this.loadCacheInfo();
      promptAction.showToast({ message: '分页缓存已清除' });
    } catch (e) {
      promptAction.showToast({ message: '清除失败' });
    } finally {
      this.clearing = false;
    }
  }
}
