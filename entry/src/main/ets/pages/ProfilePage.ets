import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { AppFont } from '../common/theme/AppFont';
import { AppThemeMode, ThemeApplier } from '../common/theme/ThemeApplier';
import { RouteName } from '../model/RouteParam';
import { bundleManager } from '@kit.AbilityKit';
import { BackupService } from '../data/service/BackupService';
import { PageCacheRepository } from '../data/repository/PageCacheRepository';
import { BookRepository } from '../data/repository/BookRepository';
import { SettingsService } from '../data/service/SettingsService';
import { IconChevron } from '../views/common/Marks';
import { ThemeConfirm } from '../views/common/ThemeConfirm';
import { Logger } from '../common/utils/Logger';

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
  /**
   * 应用级主题模式（0 跟随系统 / 1 浅色 / 2 夜间）。
   *
   * ⚠️ 与阅读页的 `ReaderTheme`（阅读设置面板里的四档背景）是两件独立的事。
   * 这里只是给「外观」分段控件一个高亮来源；切换动作见 `onThemeModePick`。
   */
  @State themeMode: number = AppThemeMode.FOLLOW_SYSTEM;

  // 主题化确认弹窗的挂载状态（与 BookShelfPage 同一套做法）
  @State private confirmVisible: boolean = false;
  @State private confirmTitle: string = '';
  @State private confirmMessage: string = '';
  @State private confirmText: string = '确定';
  @State private confirmDanger: boolean = false;
  private confirmOnYes: (() => void) | null = null;
  /** 应用版本号（关于行展示；bundleManager 读失败回退 '—'） */
  @State private versionName: string = '—';
  /** 数据操作进行中（导出/导入按钮防连点） */
  @State private backingUp: boolean = false;

  aboutToAppear(): void {
    this.loadCacheInfo();
    this.loadVersionName();
    // 同步读一次持久化值做高亮（失败按跟随系统 —— 与 ThemeApplier 的降级一致）
    try {
      this.themeMode = SettingsService.getInstance().getAppThemeMode();
    } catch (e) {
      this.themeMode = AppThemeMode.FOLLOW_SYSTEM;
    }
  }

  /** 读应用版本号（bundleManager；失败静默回退 '—'，版本号不该影响页面） */
  private loadVersionName(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionName = info.versionName;
    } catch (e) {
      this.versionName = '—';
    }
  }

  /**
   * 导出备份：生成 JSON → 弹系统保存面板。
   *
   * ⚠️ 结果提示区分四种情况：成功 / 用户取消 / 书架空 / 失败。
   */
  private async doExportBackup(): Promise<void> {
    if (this.backingUp) {
      return;
    }
    this.backingUp = true;
    try {
      const saved: boolean = await BackupService.exportToUser();
      if (saved) {
        this.getUIContext().getPromptAction().showToast({ message: '备份已保存' });
      }
      // 取消不提示 —— 用户自己点的取消，弹"已取消"是打扰
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: this.errorText(e, '导出失败') });
      Logger.error('ProfilePage', `备份导出失败: ${Logger.errText(e as Object)}`);
    } finally {
      this.backingUp = false;
    }
  }

  /**
   * 把异常翻译成可展示的中文文案。
   *
   * ⚠️ BackupService 主动抛的都是中文，但**底层异常**（fs/picker/JSON）
   * 的 message 是英文（"No such file or directory" / "Unexpected Text…"）——
   * 直接透出就是用户看到的那种 toast。规则：message 里**不含中文字符**
   * 就视为底层异常，换成调用方给的中性文案；原文只进日志。
   */
  private errorText(e: Object, fallback: string): string {
    const msg: string = (e as Error).message ?? '';
    return /[\u4e00-\u9fa5]/.test(msg) ? msg : fallback;
  }

  /**
   * 导入恢复：弹选择面板 → 合并进库 → 刷新书架缓存计数。
   *
   * ⚠️ 导入动了书签/进度，读后的 `ShelfRefreshRegistry.refresh()` 会由
   * 返回书架时触发；本页只需刷新缓存计数（数字可能与书签变化相关）。
   */
  private async doImportBackup(): Promise<void> {
    if (this.backingUp) {
      return;
    }
    this.backingUp = true;
    try {
      const result = await BackupService.importFromUser();
      if (result.cancelled) {
        return;
      }
      this.getUIContext().getPromptAction().showToast({ message: result.summary() });
      this.loadCacheInfo();
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: this.errorText(e, '导入失败') });
      Logger.error('ProfilePage', `备份导入失败: ${Logger.errText(e as Object)}`);
    } finally {
      this.backingUp = false;
    }
  }

  /** 「关于静读」行点击：落款卡片收编为居中弹窗（版权页的完整版） */
  private showAboutDialog(): void {
    this.confirmVisible = true;
    this.confirmTitle = '静读';
    this.confirmMessage =
      `版本 ${this.versionName}\n\n本地导入 · 离线阅读 · 无广告 · 不上传任何内容\n\n` +
      '所有数据只保存在本机沙箱中；备份文件请妥善保管。';
    this.confirmText = '好的';
    this.confirmDanger = false;
    this.confirmOnYes = () => {
      // 「好的」只是关闭弹窗，无额外动作
    };
  }

  private async loadCacheInfo(): Promise<void> {
    try {
      this.cacheCount = await PageCacheRepository.countAll();
    } catch (e) {
      this.cacheCount = 0;
    }
  }

  build() {
    /**
     * ⚠️ 外层 `Stack` 是为确认弹窗服务的：ThemeConfirm 是全屏浮层，
     * 必须能盖住整页（层叠语义），与 BookShelfPage 同一套做法。
     */
    Stack() {
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

          /**
           * 「外观」行：应用级深浅色的**常驻入口**。
           *
           * ⚠️ 为什么加这一行：现在切深浅色只有阅读页菜单底栏里那个
           * 「夜间」按钮一条路 —— 用户不进书、不点屏幕中间，
           * 在"我的"里找不到任何入口。三档分段控件
           * （跟随系统 / 浅色 / 夜间）把这件事放到它该在的地方。
           *
           * ⚠️ 分段控件**内联两个 Text**，不抽带参 `@Builder`：
           * 设计文档第 15/41 条（串位）。
           */
          Row() {
            Column({ space: 2 }) {
              Text('外观')
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text('跟随系统 / 常亮浅色 / 常亮夜间')
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppColor.textHint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Row() {
              Text('系统')
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(this.themeMode === AppThemeMode.FOLLOW_SYSTEM
                  ? AppColor.onPrimary : AppColor.textHint)
                .backgroundColor(this.themeMode === AppThemeMode.FOLLOW_SYSTEM
                  ? AppColor.primary : Color.Transparent)
                .textAlign(TextAlign.Center)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(AppTheme.CHIP_RADIUS - 2)
                .onClick(() => {
                  this.onThemeModePick(AppThemeMode.FOLLOW_SYSTEM);
                })

              Text('浅色')
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(this.themeMode === AppThemeMode.LIGHT
                  ? AppColor.onPrimary : AppColor.textHint)
                .backgroundColor(this.themeMode === AppThemeMode.LIGHT
                  ? AppColor.primary : Color.Transparent)
                .textAlign(TextAlign.Center)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(AppTheme.CHIP_RADIUS - 2)
                .onClick(() => {
                  this.onThemeModePick(AppThemeMode.LIGHT);
                })

              Text('夜间')
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(this.themeMode === AppThemeMode.DARK
                  ? AppColor.onPrimary : AppColor.textHint)
                .backgroundColor(this.themeMode === AppThemeMode.DARK
                  ? AppColor.primary : Color.Transparent)
                .textAlign(TextAlign.Center)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(AppTheme.CHIP_RADIUS - 2)
                .onClick(() => {
                  this.onThemeModePick(AppThemeMode.DARK);
                })
            }
          }
          .width('100%')
          .padding(14)
          .alignItems(VerticalAlign.Center)
          .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })

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
        }
        .width('100%')
        .backgroundColor(AppColor.bgCard)
        .borderRadius(AppTheme.CARD_RADIUS)
        .clip(true)
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })

      /**
       * 「数据管理」区块：备份 / 恢复。
       *
       * ⚠️ 与上面那张卡**分开**：数据备份是"用户创造的数据"的出入口，
       * 与"清除类"操作（缓存/清空）语义相反 —— 放同一张卡里，
       * 「导出备份」和「清空所有数据」上下相邻，误触的心理成本很高。
       */
      Column() {
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text('导出备份')
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text('书签、划线、笔记与阅读进度存为 JSON 文件')
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
          .opacity(this.backingUp ? 0.4 : 1)
          .onClick(() => {
            this.doExportBackup();
          })

          Row() {
            Column({ space: 2 }) {
              Text('导入恢复')
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text('从备份文件合并恢复（书按 uuid 匹配，重复自动跳过）')
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
          .opacity(this.backingUp ? 0.4 : 1)
          .onClick(() => {
            this.doImportBackup();
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

      /**
       * 「关于」区块：版本号 + 承诺文案收编。
       *
       * ⚠️ 页脚落款（静读 + 朱线 + 承诺）**移进卡片**：它从"页面装饰"
       * 变成"关于条目"，页面不再需要一个压底的 Blank。
       */
      Column() {
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text('关于静读')
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text(`版本 ${this.versionName} · 本地导入 · 离线阅读 · 不上传任何内容`)
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
            this.showAboutDialog();
          })
        }
        .width('100%')
        .backgroundColor(AppColor.bgCard)
        .borderRadius(AppTheme.CARD_RADIUS)
        .clip(true)
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })

      // ⚠️ 原「自检页」行已移入「数据管理」卡；原页脚落款已收编进「关于静读」行。

      // 主题化确认弹窗（替代系统 showAlertDialog）
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bgPage)
  }

  /**
   * 「外观」分段控件的选择处理。
   *
   * ⚠️ 顺序铁律（`ThemeApplier.applyMode` 的注释）：**先 apply 成功、再落盘**。
   * 反过来会出现"设置存了但没生效，下次启动才变"。
   *
   * ⚠️ 失败时高亮**回滚**到原值 —— 状态 UI 必须反映真实生效的状态，
   * 否则分段控件会停在用户没选中的那一档上。
   */
  private onThemeModePick(mode: number): void {
    if (mode === this.themeMode) {
      return;
    }
    const previous: number = this.themeMode;
    const ok: boolean = ThemeApplier.applyMode(mode);
    if (!ok) {
      this.themeMode = previous;
      this.getUIContext().getPromptAction().showToast({ message: '切换失败' });
      return;
    }
    this.themeMode = mode;
    try {
      SettingsService.getInstance().putAppThemeMode(mode);
    } catch (e) {
      // 落盘失败不阻塞：本次会话已生效，下次启动回退到旧值
    }
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
   * 清空所有数据：先弹主题化确认（不可撤销的破坏性操作必须二次确认），
   * 确认后才调 `BookRepository.wipeAll()`。
   *
   * ⚠️ 原 `showAlertDialog` 已替换为 `ThemeConfirm`：系统确认框是冷白卡片 +
   * 蓝色按钮，不跟随宣纸/朱砂主题，且其 `fontColor` 只收 string 字面量
   * （`AppColorLiteral` 因此存在）。ThemeConfirm 把确认框也收进令牌体系。
   */
  private confirmWipeAll(): void {
    this.confirmTitle = '清空所有数据？';
    this.confirmMessage = '将删除全部书籍、阅读进度、书签笔记与统计记录，且不可恢复。书源 TXT 文件会保留在沙箱中。';
    this.confirmText = '清空';
    this.confirmDanger = true;
    this.confirmOnYes = () => {
      this.doWipeAll();
    };
    this.confirmVisible = true;
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
