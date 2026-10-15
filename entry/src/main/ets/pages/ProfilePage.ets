import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { AppFont } from '../common/theme/AppFont';
import { RouteName } from '../model/RouteParam';
import { PageCacheRepository } from '../data/repository/PageCacheRepository';
import { BookRepository } from '../data/repository/BookRepository';
import { IconChevron } from '../views/common/Marks';

/**
 * "我的"页：设置入口、缓存清理、关于。
 *
 * ## 本次改动
 *
 * 1. **标题下一条通栏发丝线** —— 与书架页、统计页同一套结构，
 *    三个主 Tab 的分隔线因此完全对齐。
 * 2. **行尾箭头从文本字形 `›` 换成画出来的折角**（`IconChevron`）：
 *    字形 `›` 的粗细与垂直位置随字体漂移，而这里有四个箭头排成一列，
 *    四个一起漂非常显眼。
 * 3. **「自检页」加 `开发` 标签**：它是一个开发工具，混在三个用户功能里
 *    没有区分，用户会去点。标签不改功能，只说明"这不是给你用的"。
 * 4. **「清空所有数据」用危险色**：原来它与另外三行**完全同色**，
 *    只有点进弹窗才知道是破坏性操作。真正的危险项必须在**列表里**
 *    就看得出来（这也与 `promptAction` 菜单里给危险项单独上色同一套做法）。
 * 5. **行高与内边距统一成 14vp**，箭头右侧不再挤在边缘。
 * 6. **页脚落款**：「静读」加字距 + 一条 accent 短线 + 承诺文案，
 *    整块下沉到底部 —— 它是一句落款，不该紧贴在设置卡片下面。
 */
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
    Column() {
      /**
       * 标题区（带内边距）。
       *
       * ⚠️ 与下面那条通栏线**不能共处一个带内边距的容器**：线要出血到屏幕两边，
       * 所以本 build 分了三段 —— 标题自己带内边距、线不带、内容区再自己带。
       * 这与书架页、统计页是同一套结构，三个 Tab 的分隔线因此严格对齐。
       */
      Column() {
        Text('我的')
          .fontSize(AppTheme.FONT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .letterSpacing(AppTheme.TRACK_TITLE)
          .width('100%')
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_L })

      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)
        .margin({ top: AppTheme.GAP_M })

      Column() {
        Column() {
          /**
           * ⚠️ 四行**内联写死**，不用带参 `@Builder`。
           *
           * 本项目反复记录过这个坑（设计文档第 15/41 条）：带参 `@Builder`
           * 在同一处 `build()` 里被调多次时**参数会串位**——
           * 而这里恰好要调四次，且本轮还要给其中两行加不同的颜色与标签
           * （参数从 3 个涨到 5 个），串位的面积会直接扩大。
           * 代价是四段结构相似的代码，收益是"点了第 3 行绝不会执行第 1 行的事"。
           *
           * 判据：**结构相同但每份都不一样的行，宁可内联**。
           */
          Row() {
            Column({ space: 2 }) {
              Text('阅读设置')
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text('字号、行距、主题、翻页方式')
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppColor.textHint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconChevron()
          }
          .width('100%')
          .padding(14)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            // 走 UIContext 上的 Router/PromptAction：@ohos.router 与 promptAction
            // 的全局函数均已废弃（见 §5.6 第 19 条）
            this.getUIContext().getRouter()
              .pushUrl({ url: RouteName.SETTINGS_PAGE })
              .catch(() => {
                this.getUIContext().getPromptAction()
                  .showToast({ message: '设置页尚未实现' });
              });
          })

          Row() {
            Column({ space: 2 }) {
              Text('清除分页缓存')
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text(`当前 ${this.cacheCount} 条`)
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppColor.textHint)
                .fontFeature(AppFont.TABULAR)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconChevron()
          }
          .width('100%')
          .padding(14)
          .alignItems(VerticalAlign.Center)
          .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })
          .onClick(() => {
            this.clearCache();
          })

          Row() {
            Column({ space: 2 }) {
              Text('清空所有数据')
                // ⚠️ 危险色标在**列表行**上，而不是只在弹窗里
                .fontColor(AppColor.danger)
                .fontSize(AppTheme.FONT_BODY)
                .width('100%')
              Text('删除全部书籍、进度、书签与统计（书源文件保留）')
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppColor.textHint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconChevron()
          }
          .width('100%')
          .padding(14)
          .alignItems(VerticalAlign.Center)
          .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })
          .onClick(() => {
            this.confirmWipeAll();
          })

          Row() {
            Column({ space: 2 }) {
              Row({ space: AppTheme.GAP_S }) {
                Text('自检页')
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppColor.textPrimary)
                /**
                 * `开发` 标签。
                 *
                 * ⚠️ 用 1vp 描边 + 极淡文字色，而不是实心色块：
                 * 这个标签的目的是"降低存在感、同时说明它不是用户功能"，
                 * 实心色块反而会让它变成这一行最显眼的东西。
                 */
                Text('开发')
                  .fontSize(9.5)
                  .fontColor(AppColor.textHint)
                  .letterSpacing(0.5)
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  .border({ width: AppTheme.HAIRLINE, color: AppColor.divider })
                  .borderRadius(4)
              }
              .width('100%')

              Text('验证数据库与解析链路')
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppColor.textHint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconChevron()
          }
          .width('100%')
          .padding(14)
          .alignItems(VerticalAlign.Center)
          .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })
          .onClick(() => {
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
        .clip(true)
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })

      // 把落款压到底部：它是一个签名，不该紧贴在设置卡片下面
      Blank()

      /**
       * 页脚落款。
       *
       * ⚠️ 文案口径与 `SplashPage` 的 `APP_NAME` / `SLOGAN` **必须一致** ——
       * 同一个 App 不能有两种自我描述（见 `SplashPage` 顶部注释）。
       */
      Column({ space: 9 }) {
        Text('静读')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          // 大字号下才敢用这么大的字距；wordmark 的字距常量与启动页同源
          .letterSpacing(AppTheme.TRACK_WORDMARK)
          // `letterSpacing` 会在**每个字之后**（含最后一个字）加空隙，于是文字块
          // 右侧多出一个字距的空白、整块看起来偏左。补一个**等量**的左缩进把它
          // 顶回视觉居中 —— 这是排版里的常规处理，启动页的 wordmark 用的是同一招
          .padding({ left: AppTheme.TRACK_WORDMARK })
          // 与启动页的 wordmark 同源：探测到衬线才有，取不到自动回退系统字体
          .fontFamily(AppFont.titleFamily())

        Row()
          .width(22)
          .height(AppTheme.HAIRLINE)
          .backgroundColor(AppColor.accent)
          .opacity(0.75)

        Text('本地导入 · 离线阅读 · 无广告 · 不上传任何内容')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, bottom: 28 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bgPage)
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

  /**
   * 清空所有数据：先弹系统确认（不可撤销的破坏性操作必须二次确认），
   * 确认后才调 `BookRepository.wipeAll()`。
   *
   * ⚠️ 用 `getUIContext().showAlertDialog()`：`AlertDialog.show()` 全局函数
   * 自 API 18 已废弃（设计文档 §5.6 第 20 条）。
   *
   * ⚠️ 弹窗按钮上那个危险色是**字符串字面量** `'#B4432F'`，没有改成
   * `AppColor.danger`：`showAlertDialog` 的 `fontColor` 只收 `string`，
   * 塞 `Resource` 直接编译不过 —— 这与 `AppColorLiteral` 存在的理由完全相同。
   * 若要改色，请同时改 `AppColorLiteral.danger`（那里才是唯一来源）。
   */
  private confirmWipeAll(): void {
    this.getUIContext().showAlertDialog({
      title: '清空所有数据？',
      message: '将删除全部书籍、阅读进度、书签笔记与统计记录，且不可恢复。书源 TXT 文件会保留在沙箱中。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#B4432F',
        action: () => {
          this.doWipeAll();
        }
      }
    });
  }

  private async doWipeAll(): Promise<void> {
    if (this.clearing) {
      return;
    }
    this.clearing = true;
    try {
      await BookRepository.wipeAll();
      this.cacheCount = 0;
      this.getUIContext().getPromptAction().showToast({ message: '已清空全部数据' });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '清空失败' });
    } finally {
      this.clearing = false;
    }
  }
}
