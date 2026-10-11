import { AppColor, AppTheme } from '../common/theme/AppTheme';
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
        .fontColor(AppColor.textPrimary)
        .width('100%')

      Column() {
        this.settingRow('阅读设置', '字号、行距、主题、翻页方式', () => {
          // 走 UIContext 上的 Router/PromptAction：@ohos.router 与 promptAction
          // 的全局函数均已废弃（见 §5.6 第 19 条）
          this.getUIContext().getRouter()
            .pushUrl({ url: RouteName.SETTINGS_PAGE })
            .catch(() => {
              this.getUIContext().getPromptAction()
                .showToast({ message: '设置页尚未实现' });
            });
        })
        Divider().color(AppColor.divider)

        this.settingRow('清除分页缓存', `当前 ${this.cacheCount} 条`, () => {
          this.clearCache();
        })
        Divider().color(AppColor.divider)

        this.settingRow('自检页（开发用）', '验证数据库与解析链路', () => {
          this.getUIContext().getRouter()
            .pushUrl({ url: 'pages/SelfCheckPage' })
            .catch(() => {
              this.getUIContext().getPromptAction()
                .showToast({ message: '未找到自检页' });
            });
        })
      }
      .width('100%')
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)

      Column({ space: 4 }) {
        Text('静读')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
        Text('本地导入 · 离线阅读 · 无广告 · 不上传任何内容')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding(AppTheme.GAP_M)

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding(AppTheme.PAGE_PADDING)
    .backgroundColor(AppColor.bgPage)
  }

  @Builder
  settingRow(title: string, subtitle: string, onTap: () => void) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppColor.textPrimary)
          .width('100%')
        Text(subtitle)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor(AppColor.textHint)
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
      this.getUIContext().getPromptAction().showToast({ message: '分页缓存已清除' });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '清除失败' });
    } finally {
      this.clearing = false;
    }
  }
}
