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
     *
     * ⚠️ 内层 `Column` **必须显式 `height('100%')`**（本次修复的关键）：
     * `Stack` 的默认对齐是**居中**，而"不写高度"的 `Column` 高度是**包裹内容**的
     * —— 于是整列内容（标题 + 卡片 + 落款）被当成一整块、在页面里**垂直居中**：
     * 顶部空出一大截（用户反馈的"标题不在最上面"），
     * 底部那句落款也跟着浮在半空、离导航栏很远（用户反馈的第二件事）。
     *
     * 写满高度之后两件事一起解决：
     *  1. 标题贴到顶部（顶部留白只剩 `GAP_S` + 安全区）；
     *  2. `Blank()` 有了可吃的余量，把落款顶到底、停在导航栏上方。
     *
     * 判据：**`Blank()` / `layoutWeight` 这类"吃余量"的东西，
     * 父容器必须有确定高度**，否则它们一分余量都拿不到（等于没写）。
     */
    Stack() {
     Column() {
      /**
       * 标题区（带内边距）。
       *
       * ⚠️ 与下面那条通栏线**不能共处一个带内边距的容器**：线要出血到屏幕两边，
       * 所以本 build 分了三段 —— 标题自己带内边距、线不带、内容区再自己带。
       * 这与书架页、统计页是同一套结构，三个 Tab 的分隔线因此严格对齐。
       *
       * ⚠️ 顶部留白收到 `GAP_S`（效果稿里标题是**贴着状态栏**的）：
       * 原来用 `GAP_L`(16) 加安全区，标题看起来"悬在半空"。
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
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_S })

      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)
        .margin({ top: AppTheme.GAP_M })

      Column() {
        /**
         * 分组眉标（效果稿的「阅 读」）：把"设置类"与下面的"数据类"分开。
         *
         * ⚠️ 用 10vp + 大字距的灰字，不用色块/加粗 ——
         * 眉标是**分层**信息，不是标题，抢戏就失去了分层的作用。
         */
        Text('阅 读')
          .fontSize(10)
          .fontColor(AppColor.textHint)
          .letterSpacing(3)
          .width('100%')
          .padding({ left: 2, bottom: 10 })

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
            Column({ space: 3 }) {
              Text('阅读设置')
                .fontSize(16)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text('字号、行距、背景、翻页方式')
                .fontSize(12)
                .fontColor(AppColor.textHint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconChevron()
          }
          .width('100%')
          .padding({ top: 17, bottom: 17, left: 18, right: 18 })
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
           * ⚠️ 为什么加这一行：切深浅色不能只有阅读页菜单底栏那个「夜间」
           * 一条路 —— 用户不进书、不点屏幕中间，在"我的"里也得找得到。
           *
           * ⚠️ 控件形态：**小圆角方形分段选择器**（效果稿的样子，不是胶囊）。
           *  - 三档 `layoutWeight(1)` **等分**，选中档墨色实心；
           *  - 圆角取 **6**（`ITEM_RADIUS` 的 3/4）而不是 `CHIP_RADIUS`(14)：
           *    14 会把它读成"三颗胶囊"，6 才是"一个方形控件被分成三格"；
           *  - 外层一条发丝描边 + 槽底 `bgCard`，把三档圈成**一个控件**。
           *
           * ⚠️ 三段**内联写死**，不抽带参 `@Builder`：设计文档第 15/41 条（串位）。
           */
          Row() {
            Column({ space: 3 }) {
              Text('外观')
                .fontSize(16)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text('跟随系统 / 常亮浅色 / 常亮夜间')
                .fontSize(12)
                .fontColor(AppColor.textHint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Row() {
              Text('系统')
                .fontSize(12)
                .fontColor(this.themeMode === AppThemeMode.FOLLOW_SYSTEM
                  ? AppColor.onPrimary : AppColor.textSecondary)
                .backgroundColor(this.themeMode === AppThemeMode.FOLLOW_SYSTEM
                  ? AppColor.primary : Color.Transparent)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .padding({ top: 5, bottom: 5 })
                .borderRadius(4)
                .onClick(() => {
                  this.onThemeModePick(AppThemeMode.FOLLOW_SYSTEM);
                })

              Text('日间')
                .fontSize(12)
                .fontColor(this.themeMode === AppThemeMode.LIGHT
                  ? AppColor.onPrimary : AppColor.textSecondary)
                .backgroundColor(this.themeMode === AppThemeMode.LIGHT
                  ? AppColor.primary : Color.Transparent)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .padding({ top: 5, bottom: 5 })
                .borderRadius(4)
                .onClick(() => {
                  this.onThemeModePick(AppThemeMode.LIGHT);
                })

              Text('夜间')
                .fontSize(12)
                .fontColor(this.themeMode === AppThemeMode.DARK
                  ? AppColor.onPrimary : AppColor.textSecondary)
                .backgroundColor(this.themeMode === AppThemeMode.DARK
                  ? AppColor.primary : Color.Transparent)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .padding({ top: 5, bottom: 5 })
                .borderRadius(4)
                .onClick(() => {
                  this.onThemeModePick(AppThemeMode.DARK);
                })
            }
            .width(144)
            .padding(2)
            // 外框：小圆角方形（6）+ 发丝描边，把三档圈成一个控件
            .border({ width: AppTheme.HAIRLINE, color: AppColor.divider })
            .borderRadius(6)
            .backgroundColor(AppColor.bgCard)
          }
          .width('100%')
          .padding({ top: 15, bottom: 15, left: 18, right: 18 })
          .alignItems(VerticalAlign.Center)
          .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })

          Row() {
            Column({ space: 3 }) {
              Text('清除分页缓存')
                .fontSize(16)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text(`当前 ${this.cacheCount} 条`)
                .fontSize(12)
                .fontColor(AppColor.textHint)
                .fontFeature(AppFont.TABULAR)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconChevron()
          }
          .width('100%')
          .padding({ top: 17, bottom: 17, left: 18, right: 18 })
          .alignItems(VerticalAlign.Center)
          .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })
          .onClick(() => {
            this.clearCache();
          })

          Row() {
            Column({ space: 3 }) {
              Text('清空所有数据')
                // ⚠️ 危险色标在**列表行**上，而不是只在弹窗里
                .fontColor(AppColor.danger)
                .fontSize(16)
                .width('100%')
              Text('删除全部书籍、进度、书签与统计（书源文件保留）')
                .fontSize(12)
                .fontColor(AppColor.textHint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconChevron()
          }
          .width('100%')
          .padding({ top: 17, bottom: 17, left: 18, right: 18 })
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
        Text('数 据')
          .fontSize(10)
          .fontColor(AppColor.textHint)
          .letterSpacing(3)
          .width('100%')
          .padding({ left: 2, bottom: 10 })

        Column() {
          Row() {
            Column({ space: 3 }) {
              Text('导出备份')
                .fontSize(16)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text('书签、划线、笔记与阅读进度存为 JSON 文件')
                .fontSize(12)
                .fontColor(AppColor.textHint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconChevron()
          }
          .width('100%')
          .padding({ top: 17, bottom: 17, left: 18, right: 18 })
          .alignItems(VerticalAlign.Center)
          .opacity(this.backingUp ? 0.4 : 1)
          .onClick(() => {
            this.doExportBackup();
          })

          Row() {
            Column({ space: 3 }) {
              Text('导入恢复')
                .fontSize(16)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text('从备份文件合并恢复（书按 uuid 匹配，重复自动跳过）')
                .fontSize(12)
                .fontColor(AppColor.textHint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconChevron()
          }
          .width('100%')
          .padding({ top: 17, bottom: 17, left: 18, right: 18 })
          .alignItems(VerticalAlign.Center)
          .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })
          .opacity(this.backingUp ? 0.4 : 1)
          .onClick(() => {
            this.doImportBackup();
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
       * 把落款压到底部：它是一个签名，不该紧贴在设置卡片下面。
       *
       * ⚠️ 它能生效的**前提**是外层 `Column` 有确定高度（见 `build()` 顶部说明）——
       * `Blank()` 吃的是"父容器分完其余子节点后的余量"，
       * 父容器高度由内容决定时余量恒为 0，`Blank()` 等于没写，
       * 整列还会被 `Stack` 垂直居中（这正是"标题不在最上面、
       * 落款浮在半空"两个问题的同一个根因）。
       */
      Blank()

      /**
       * 页脚落款 —— **一个短横 + 两行字**：
       * ```
       *            ──        ← 24×1vp 点缀色短横（在静读之上）
       *         静读 v1.0.0
       *   本地导入 · 离线阅读 · 无广告
       * ```
       *
       * ⚠️ 文案口径与 `SplashPage` 的 `APP_NAME` / `SLOGAN` **必须一致** ——
       * 同一个 App 不能有两种自我描述（见 `SplashPage` 顶部注释）。
       *
       * ⚠️ 相对上一版删掉了「不上传任何内容」与「自检页 · 开发」两行：
       * 落款只保留"名字 + 版本 + 一句定位"，越短越像落款。
       * 版本号与 wordmark 同行（缀在其右），不再各占一行。
       *
       * ⚠️ **「静读」的字号与字色改成与下面那句承诺完全一致**（用户要求），
       * 因此这里删掉了原来的两处"wordmark 专属"处理：
       *  - `TRACK_WORDMARK`(4vp) 大字距 —— 那条注释自己写的是
       *    "大字号下才敢用这么大的字距"，字号降到 12 之后 4vp 的字距
       *    会让两个字之间空出一个字的宽度，读起来像排版事故；
       *  - 为抵消字距而补的等量左内边距（`padding({left: 4})`）——
       *    它存在的唯一目的就是配平那个字距，字距没了它只会让文字偏右。
       * 两者是一对，删一个留一个必然歪，所以一起删。
       *
       * ⚠️ 保留 `Bold` 与衬线族：它们**不是**字号/字色，仍用来把"应用名"
       * 与"一句定位"分开（衬线在手机上基本取不到，实际回退系统字体，无副作用）。
       *
       * ⚠️ 底部留白收到 12（原来 24）：落款要**贴着底部**，
       * 上面那个 `Blank()` 已经把它推到底，再留一大截就飘了。
       */
      Column({ space: 8 }) {
        /**
         * 落款短横 —— **在「静读」之上**（用户指定）。
         *
         * ⚠️ 位置**故意与效果稿不同**，不要照着效果稿"改回去"：
         * `ui-proposal.html` 的 `.colophon` 是「mark(静读) → rule → promise」，
         * 短线夹在应用名与承诺之间当**分隔**；用户要求的是把它提到最上方，
         * 于是这里读作「短线 → 静读 → 承诺」—— 短线成了落款的**起首**。
         * 两种都成立（一个收尾、一个起首），以用户指定为准。
         *
         * ⚠️ 高度复用 `HAIRLINE`(1vp)、宽度与不透明度取
         * `COLOPHON_RULE_*` 令牌：它是一条发丝线，不是色块。
         * 写成 2vp 或满强度都会从"起首"变成"焦点"。
         */
        Row()
          .width(AppTheme.COLOPHON_RULE_W)
          .height(AppTheme.HAIRLINE)
          .backgroundColor(AppColor.accent)
          .opacity(AppTheme.COLOPHON_RULE_ALPHA)

        // 「静读」+ 版本号：同一行居中（版本用 10vp 灰字，缀在应用名右侧）
        Row({ space: 7 }) {
          Text('静读')
            // ⚠️ 字号与字色 = 下面那句承诺，两者必须同源，不要各写一个字面量
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
            .fontWeight(FontWeight.Bold)
            // 与启动页的 wordmark 同源：探测到衬线才有，取不到自动回退系统字体
            .fontFamily(AppFont.titleFamily())

          Text(`v${this.versionName}`)
            .fontSize(10)
            .fontColor(AppColor.textHint)
            .fontFeature(AppFont.TABULAR)
            /**
             * ⚠️ 从 6 收到 2：原来那 6 是为"17vp 应用名 + 10vp 版本号"补的
             * 基线落差，字号降到 12 之后落差只剩 2vp，再留 6 会把版本号压到
             * 应用名的下缘以下、看着像掉下去了。
             */
            .margin({ top: 2 })
        }
        .alignItems(VerticalAlign.Center)

        Text('本地导入 · 离线阅读 · 无广告')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, bottom: 12 })
      .alignItems(HorizontalAlign.Center)

      /**
       * 主题化确认弹窗（替代系统 showAlertDialog）—— 见本 `build()` 末尾的说明：
       * 它挂在**外层 Stack** 上，不在这里参与 `Column` 的纵向布局
       */
     }
     // ⚠️ 见 `build()` 顶部说明：不写高度，整列会被 Stack 居中、落款浮在半空
     .width('100%')
     .height('100%')

     /**
      * 主题化确认弹窗（替代系统 showAlertDialog）。
      *
      * ⚠️ 它是**外层 `Stack` 的子节点**，不是里面 `Column` 的子节点 ——
      * 这正是外面那层 `Stack` 存在的理由（见 `build()` 顶部注释）。
      * 放在 `Column` 里会参与纵向布局：它自己 `height('100%')`，
      * 与 `Blank()` / 落款抢同一段高度，弹窗一开整页就会被撑歪。
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
