import { AppColor, AppTheme, ReaderTheme } from '../common/theme/AppTheme';
import { AppFont } from '../common/theme/AppFont';
import { AppThemeMode, ThemeApplier } from '../common/theme/ThemeApplier';
import { bundleManager } from '@kit.AbilityKit';
import { BackupService } from '../data/service/BackupService';
import { PageCacheRepository } from '../data/repository/PageCacheRepository';
import { BookRepository } from '../data/repository/BookRepository';
import { SettingsService } from '../data/service/SettingsService';
import { ReaderSettings } from '../model/ReaderSettings';
import { IconChevron } from '../views/common/Marks';
import { ThemeConfirm } from '../views/common/ThemeConfirm';
import { Logger } from '../common/utils/Logger';
import { PathUtil } from '../common/utils/PathUtil';
import { FileUtil } from '../common/utils/FileUtil';

/**
 * 「阅读主题」色块的宽度（vp）。
 *
 * ⚠️ 必须**固定宽度**而不是 `layoutWeight(1)` 等分：等分只在"五档刚好放得下"
 * 时成立，而用户要求这一行**横向可滑动** —— 可滑动的前提是内容有确定的宽度，
 * 用等分会被父容器压成一行、滑不动（`Scroll` 里的 `layoutWeight` 没有意义）。
 *
 * ⚠️ 取 56：五档合计 56×5 + 间距 8×4 = 312vp，而卡内可用宽度约 292vp
 * （360vp 屏 − 页面左右各 16 − 卡内左右各 18）—— 于是**第五块会露出小半截**，
 * 天然提示"这一行还能往右滑"。刻意不做成"刚好放得下"：那样用户不会知道
 * 还有内容，也不会知道能滑。
 */
const THEME_SWATCH_W: number = 56;

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
  /**
   * **阅读页正文**背景方案（light / warm / sepia / eye_care / dark）。
   *
   * ⚠️ 与上面的 `themeMode`（应用级深浅色）是**两件独立的事**，
   * 这不是重复而是刻意分开（见 `SettingsKeys.THEME` 的注释）：
   *  - `themeMode` 走系统 `setColorMode`，改的是整个 app 的深浅色；
   *  - 本项只改**阅读页正文背景** —— 用户选的护眼绿不该被系统深色覆盖。
   * 两件事各自有卡片（「外观」与「阅读主题」），不要合并。
   */
  @State private readerTheme: string = 'light';

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
  /** 沙箱内书籍文件总占用（格式化文案；空串 = 还没量到/量失败） */
  @State private storageUsageText: string = '';

  aboutToAppear(): void {
    this.loadCacheInfo();
    this.loadVersionName();
    this.loadStorageUsage();
    // 同步读一次持久化值做高亮（失败按跟随系统 —— 与 ThemeApplier 的降级一致）
    try {
      this.themeMode = SettingsService.getInstance().getAppThemeMode();
    } catch (e) {
      this.themeMode = AppThemeMode.FOLLOW_SYSTEM;
    }
    // 阅读页正文背景：与上面那次读取**分开 try** ——
    // 一项读失败不该把另一项的高亮也带回默认值
    try {
      this.readerTheme = SettingsService.getInstance().loadReaderSettings().theme;
    } catch (e) {
      this.readerTheme = 'light';
    }
  }

  /**
   * 「阅读主题」选中某档。
   *
   * ⚠️ 落盘走 `saveReaderSettings`（整份设置一起写），因此必须
   * **先读回当前设置、只改 theme 再存**，不能 new 一份默认值 ——
   * 那会把用户的字号/行距/翻页方式全部重置成默认
   * （本项目 `ReaderSettings` 有十几个字段，这里只该动一个）。
   *
   * ⚠️ 失败时高亮**回滚**到原值：状态 UI 必须反映真实生效的值，
   * 否则卡片会停在用户没选中的那一档上（与 `onThemeModePick` 同一纪律）。
   *
   * ⚠️ 这里**不清理分页缓存**：`theme` 不进 `PaginationService.buildLayoutKey`
   * （它只影响颜色，不影响断行），改它不会让旧断点失效。
   * 顺手清一次反而会让用户下次打开书时白重排一遍。
   */
  private onReaderThemePick(name: string): void {
    if (name === this.readerTheme) {
      return;
    }
    const previous: string = this.readerTheme;
    try {
      const next: ReaderSettings = SettingsService.getInstance().loadReaderSettings();
      next.theme = name;
      SettingsService.getInstance().saveReaderSettings(next);
      this.readerTheme = name;
    } catch (e) {
      this.readerTheme = previous;
      this.getUIContext().getPromptAction().showToast({ message: '切换失败' });
      Logger.error('ProfilePage', `阅读主题保存失败: ${Logger.errText(e as Object)}`);
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

  /**
   * 统计沙箱内书籍文件的总占用并格式化。
   *
   * ⚠️ 同步遍历放在 `setTimeout(0)` 里让出一帧：进页面先画出来、
   * 数字随后补上（几十 MB / 几十个文件的遍历是毫秒级，肉眼无感），
   * 避免在首帧的构建路径里做文件 IO。
   *
   * ⚠️ 统计失败显示「-」而不是 0 B：0 会被读成"没占空间"，
   * 而失败是"不知道"，两者语义不同。
   */
  private loadStorageUsage(): void {
    this.storageUsageText = '';
    setTimeout(() => {
      try {
        const bytes: number = PathUtil.sandboxUsage();
        this.storageUsageText = bytes > 0 ? FileUtil.humanSize(bytes) : '0 B';
      } catch (e) {
        this.storageUsageText = '-';
        Logger.warn('ProfilePage', `统计存储占用失败: ${Logger.errText(e as Object)}`);
      }
    }, 0);
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
           * ⚠️ **本卡片有两块**：「外观」行（应用级深浅色）与
           * 「阅读主题」卡（阅读页正文背景）。两者是独立设置，见
           * `readerTheme` 字段的说明 —— 不要合并成一个控件。
           *
           * ⚠️ 多行仍然**内联写死**，不用带参 `@Builder`：
           * 设计文档第 15/41 条（带参 `@Builder` 在同一处 `build()` 里
           * 被调多次时参数会串位）。本卡片恰好调两次，且两块形态完全不同
           * （一行分段控件 vs 一行色块），串位的代价远大于省下的几行。
           */

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
          /**
           * ⚠️ **没有上边框** —— 它是本卡片的第一行。
           * 行的分隔线语义是"与上一行分开"，第一行之上没有上一行。
           * 判据：**分隔线画在"两行之间"，不是画在"每一行上"。**
           */
        }
        .width('100%')
        .backgroundColor(AppColor.bgCard)
        .borderRadius(AppTheme.CARD_RADIUS)
        .clip(true)

      /**
       * 「阅读主题」—— 阅读页正文背景的五档选择（从阅读设置面板搬来）。
       *
       * ⚠️ **本卡必须在「阅 读」区块的 `Column` 之内**（即与上面的「外观」卡
       * 同级、共用一个带 `PAGE_PADDING` 的父容器）。本项目实测踩过：
       * 曾经把区块的 `}` 提前收在「外观」卡之后，于是本卡成了页面级兄弟节点、
       * **左右贴到屏幕边缘**，与上下所有卡片都对不起 —— 用户反馈"边距不一样"。
       * 判据：**左右留白由外层统一给；只要发现某张卡比别的宽，先查它是不是
       * 被放到了带内边距的那一层之外。**
       *
       * ⚠️ **单独一张卡，不与「外观」合并**（用户要求"做一个主题的卡片"）：
       *  - 两者是**独立设置**：外观改整个 app 的深浅色，本卡只改阅读页正文背景；
       *  - 形态也差得远：上面是一行 40vp 高的分段控件，本卡是三段式
       *    （标题 + 色块 + 文字标签）。
       *
       * ⚠️ **为什么值得在"我的"里再来一份**：它原先只能进书、点屏幕中间才能改。
       * 而"阅读背景"是用户**买前就会关心**的一项（护眼/夜间），
       * 在设置页找不到会以为没有。
       *
       * ⚠️ 版面对齐用户要求的三段式：
       *   ① 标题「阅读主题」
       *   ② 色块（**横向可滑动**，见下）
       *   ③ 每块下方**对应的文字**（浅色/暖白/羊皮纸/护眼/夜间）
       *
       * ⚠️ **色块行横向可滑动**（用户要求）：五档挤在一行里时每块只有约 52vp，
       * 标签"羊皮纸"三个字几乎没有余量、点按目标也偏小。改成固定宽度 +
       * 横向滚动后，每块拿到舒适的宽度与点按面积；将来加档也不必重排版
       * （与 `SettingsPanel.buildThemeRow` 里"加一档也不用重排版"的意图一致）。
       * ⚠️ 滚动条**关掉**：五档只多出一点点，一条滚动条比露出的半块更吵 ——
       * 露出的半块色块本身就是"还能滑"的提示。
       *
       * ⚠️ 色块用**该主题自己的 bg/text**（所见即所得），
       * 与 `SettingsPanel.buildThemeRow` 完全同一套写法 ——
       * 两个入口改的是同一个设置，长得不一样会让人以为是两件事。
       * 注意这里**刻意不传** `appDark`：预览必须显示各主题的真实配色，
       * 否则全局夜间下五个色块会全变成黑的。
       *
       * ⚠️ 选中态用**朱色描边 + 右下角折角**（与设置面板同一表达）：
       * 五块之间 0.5vp 的粗细差几乎不可辨，朱边 + 折角才是确定的表达。
       */
      Column() {
        Text('阅读主题')
          .fontSize(16)
          .fontColor(AppColor.textPrimary)
          .width('100%')
          .padding({ left: 18, right: 18, top: 15, bottom: 10 })

        /**
         * ⚠️ 横向滚动区：**左右内边距加在里面的 `Row` 上**，不加在 `Scroll` 上。
         * 加在 `Scroll` 上会让内容被裁在留白之后 —— 第一块贴不到 18vp，
         * 最后一块也永远滑不到完整可见。与目录页的筛选条同一套做法。
         */
        Scroll() {
          Row({ space: AppTheme.GAP_S }) {
            ForEach(ReaderTheme.THEMES, (name: string) => {
              Column({ space: 5 }) {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  Text('文')
                    .fontSize(AppTheme.FONT_SUBTITLE)
                    .fontColor(ReaderTheme.of(name).text)
                    .width('100%')
                    .height(44)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(ReaderTheme.of(name).bg)
                    .borderRadius(AppTheme.ITEM_RADIUS)
                    .border({
                      width: this.readerTheme === name ? 1.5 : 1,
                      color: this.readerTheme === name
                        ? AppColor.accent
                        : AppColor.divider
                    })

                  // 折角：右下角一枚小三角（选中时才画）
                  if (this.readerTheme === name) {
                    Row()
                      .width(0)
                      .height(0)
                      .border({
                        width: { top: 7, left: 7 },
                        color: { top: Color.Transparent, left: AppColor.accent }
                      })
                      .margin({ right: 1, bottom: 1 })
                  }
                }
                .width('100%')

                Text(ReaderTheme.labelOf(name))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(this.readerTheme === name
                    ? AppColor.accent
                    : AppColor.textHint)
                  .maxLines(1)
                  .textAlign(TextAlign.Center)
                  .width('100%')
              }
              // ⚠️ 固定宽度（不是 layoutWeight）：等分只在"刚好放得下"时成立，
              // 要让它可滑动就必须给出确定宽度，否则内容会被压缩成一行。
              .width(THEME_SWATCH_W)
              .onClick(() => {
                this.onReaderThemePick(name);
              })
            }, (name: string) => name)
          }
          .padding({ left: 18, right: 18, bottom: 15 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .width('100%')
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)
      .clip(true)
      .margin({ top: AppTheme.GAP_M })
      /**
       * ⚠️ 下面这个 `}` 收的是**「阅 读」区块的 `Column`**（从 `Text('阅 读')`
       * 那一行开始），不是阅读主题卡 —— 本卡的 `}` 是上一行那个。
       *
       * ⚠️ 本卡的缩进与「阅 读」的 `Column` 相同，看起来像兄弟节点，
       * 实际是**父子**：它必须在这一层之内才能继承 `PAGE_PADDING`。
       * 这正是上面那条"边距不一样"的坑，读代码时**以 `}` 的配对为准，
       * 不要被缩进误导**。（本轮只改行为、没有整块重排缩进，
       * 以免在无法编译验证的情况下大范围移动代码。）
       */
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })

      /**
       * 「数 据」区块：备份 / 恢复 / 清理。
       *
       * ⚠️ **原「清除分页缓存」「清空所有数据」两行从上面的「阅 读」卡片
       * 移到了这里**（用户要求），理由是"按操作对象分组"：
       *  - 「阅 读」= 改变**阅读观感**的设置（外观）；
       *  - 「数 据」= 对**数据本身**的增删出入（备份、恢复、清理）。
       *
       * 判据：**看一个操作"动了什么"，而不是"由什么产生"。**
       * 分页缓存虽然由排版参数产生，但它是一张会被 DELETE 的表、界面上
       * 也以条数（"当前 N 条"）呈现 —— 那是数据量，不是阅读偏好；
       * 清空缓存前后正文的字号/行距/背景完全一样。
       * `PageCacheRepository` 自己也把 `page_cache` 称作"**纯派生数据**"。
       *
       * ⚠️ **行序有硬约束：「清空所有数据」必须排在最末**（用户要求，
       * 也与本卡片原先的顾虑一致）：
       * 它是不可逆的破坏性操作，与「导出备份」「导入恢复」语义相反 ——
       * 紧邻摆放会把"备份"和"清空"放在同一个拇指落点附近，误触代价极高。
       * 放在最后一行，它与上面每个安全操作之间都隔着至少一行。
       * 判据：**破坏性操作放在列表末端，且不与它的反义操作相邻。**
       */
      Column() {
        Text('数 据')
          .fontSize(10)
          .fontColor(AppColor.textHint)
          .letterSpacing(3)
          .width('100%')
          .padding({ left: 2, bottom: 10 })

        Column() {
          /**
           * 「存储占用」—— **只读信息行**（无 chevron、不可点击）。
           *
           * ⚠️ 刻意与下面的操作行长得不一样：同一页里"数据"与"入口"
           * 必须可区分（设计文档既定判据）—— 它没有箭头、没有按压态，
           * 值只在进页面时算一次（导入/清除缓存后回来会重新算）。
           *
           * ⚠️ 排在本卡首行：它是"背景信息"，不是操作；
           * 用户从上往下扫到的是"现在占了多少 → 导出 → 恢复 → 清缓存 → 清空"，
           * 决策链自然。
           */
          Row() {
            Column({ space: 3 }) {
              Text('存储占用')
                .fontSize(16)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text(this.storageUsageText.length > 0
                ? `书籍与数据文件共 ${this.storageUsageText}`
                : '正在统计…')
                .fontSize(12)
                .fontColor(AppColor.textHint)
                .fontFeature(AppFont.TABULAR)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: 17, bottom: 17, left: 18, right: 18 })
          .alignItems(VerticalAlign.Center)

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
          .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })
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

          /**
           * 「清除分页缓存」—— 从上面的「阅 读」卡片移来（见本卡片顶部说明）。
           *
           * ⚠️ 副标题必须**实时反映真实条数**：`当前 N 条` 由 `cacheCount` 驱动，
           * 用户点完这一行后它应当立刻变成 0（`clearCache()` 里会重新 `loadCacheInfo()`）。
           *
           * ⚠️ 它排在备份/恢复**之后**：本行是"清理派生数据"，
           * 与上面两行的"用户数据出入口"是两件事，但都无害、可随时再做，
           * 因此可以相邻；真正要隔离的是下面那一行。
           */
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
          .opacity(this.clearing ? 0.4 : 1)
          .onClick(() => {
            this.clearCache();
          })

          /**
           * 「清空所有数据」—— **本卡片最后一行**（见本卡片顶部说明：
           * 破坏性操作必须在末端，且不与「导出备份」相邻）。
           *
           * ⚠️ 危险色标在**列表行**上，而不是只在确认弹窗里：
           * 只在弹窗里上色的话，用户在**点之前**完全看不出这是破坏性操作。
           */
          Row() {
            Column({ space: 3 }) {
              Text('清空所有数据')
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
          .opacity(this.clearing ? 0.4 : 1)
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
