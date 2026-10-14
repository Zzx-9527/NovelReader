import { AppTheme, ReaderTheme } from '../../common/theme/AppTheme';

/**
 * 三个入口的图标边长（vp，正方形）。
 *
 * ⚠️ 取 18 而不是更大：图标是这三块的**主锚点**，但不能喧宾夺主 ——
 * 22 时图标明显压过标签文字，整行显得头重脚轻（用户反馈"整体偏大"）。
 * 18 与 14 的标签文字差 4vp，主次分明又不失衡。
 *
 * ⚠️ 它**不跟随正文字号** —— 理由同 `AppTheme.FONT_BAR_TEXT`。
 */
const ICON_SIZE: number = 18;

/**
 * 图标与标签文字之间的间距（vp）。
 *
 * ⚠️ 原来只有 2：图标下沿与文字上沿几乎贴在一起，
 * 看着像一个糊在一起的色块（用户要求"加一点点间距"）。
 * 取 5 让两者有清晰的呼吸感，又不至于把整块拉得太高。
 */
const ICON_LABEL_GAP: number = 5;

/**
 * 三个入口**标签文字**的字号（vp）。
 *
 * ⚠️ 比 `AppTheme.FONT_BAR_TEXT`(16) 小两号 —— 这是刻意的层级区分：
 *  - 上一行"上一章/下一章"是**主操作**，与顶栏"返回"同字号（用户要求过对应）；
 *  - 这一行是**次级导航**（目录/夜间/设置），小一号才不喧宾夺主，
 *    也正好满足"整体变小"的要求。
 *
 * ⚠️ 想让它与上一行齐平就把这里改成 `AppTheme.FONT_BAR_TEXT`；
 * 但那样三块会明显变高，本栏会往上多占一截阅读区。
 */
const LABEL_FONT_SIZE: number = 14;

/**
 * 阅读页**菜单底栏**（点屏幕中间才出现，负责"操作"）。
 *
 * 版面（从上到下）：
 * ```
 * [上一章] ============进度条============ [下一章]
 * ─────────────────────────────────────────────
 *    contents        dark / light       settings
 *     目录           夜间 / 日间          设置
 * ```
 *
 * ⚠️ 三个入口都带**图标 + 文字**：只有文字时三块看起来像纯文本，
 * 拇指落下去没有"按钮"的实感；图标同时让三块在视觉上等重、更易区分。
 * "夜间"那一块的图标与文案随状态切换（dark.svg ↔ light.svg），见其实现处的说明。
 *
 * ⚠️ 图标用 `resources/base/media/` 下的 **SVG**（`contents` / `dark` /
 * `light` / `settings`），配 `.fillColor()` 染色跟随阅读页主题。
 *
 * 这批 SVG 带不带写死的 `fill` **都不影响染色** —— 官方文档明确
 * `fillColor` 会"替换 svg 图片中所有可绘制元素的填充颜色"。
 * （已实测确认：`bookshelf.svg`/`stats.svg` 带 `fill="#303133"` 之类，
 * 首页 Tab 用 `fillColor` 一样能正常染色。）
 * 所以换图标时**不必**去检查 `fill` 属性 —— 这一点与"用 `colorFilter`
 * 给 PNG 染色"完全不同，别把两者的前提条件混在一起。
 *
 * ⚠️ 本栏**只放操作**，不放任何"告知类"信息 ——
 * 章节名、页码、全书百分比全部由阅读页的**常驻底栏**
 * （`ReaderPage.buildReaderFooter`）承担，它永远可见。
 *
 * ⚠️ 三个入口（目录/夜间/设置）放在**最下面一行、等分三块**，
 * 而不是挤在顶行右侧：拇指自然落在屏幕底部，
 * 顶行右角是单手最难够到的位置（用户要求如此排布）。
 * 原顶行右侧那个"设置"因此取消 —— 同一功能不留两个入口。
 *
 * ⚠️ 展示值必须用 `@Prop`：普通成员只在组件**创建时**取一次快照，
 * 父组件后续的状态变化不会同步进来 —— 表现为"拖动进度条后数字又弹回去"。
 *
 * 拖动过程中只更新本地状态（draggingPercent），松手才真正跳章（SliderChangeMode.End），
 * 避免拖动时反复触发重排。
 */
@Component
export struct ReaderBottomBar {
  /**
   * 阅读页配色。
   *
   * ⚠️ **必须是 `@Prop`**：普通成员只在创建时快照 ——
   * 点"夜间"后正文变黑、本栏却仍是白底，就是这个原因
   * （关掉菜单再打开会重建组件、重新取快照，所以看着"又正常了"）。
   * 与 `ReaderTopBar` / 书架卡片是同一个坑，详见那边的说明。
   */
  @Prop theme: ReaderTheme = new ReaderTheme();
  /** 0~1 */
  @Prop percent: number = 0;
  /** 是否还有上一章 / 下一章：首末章时把按钮置灰 */
  @Prop hasPrev: boolean = false;
  @Prop hasNext: boolean = false;
  /**
   * 底部安全区（手势条）高度，vp。
   *
   * ⚠️ 本栏要盖住常驻底栏、铺到屏幕最底边，所以必须自己把这一段也涂上色；
   * 由父组件传入（它从 `AppStorage` 拿得到，本组件拿不到）。
   */
  @Prop safeAreaBottom: number = 0;
  /**
   * 应用级主题当前是否为夜间，用于"夜间"入口的高亮态。
   *
   * ⚠️ 这**不是**阅读页正文背景（那是 `ReaderTheme`）——
   * 本项指整个 app 的深浅色，由 `ThemeApplier` 发布到 `AppStorage`。
   * 必须是 `@Prop`：普通成员只在创建时快照，切换后高亮不跟着走。
   */
  @Prop appDarkMode: boolean = false;
  onJump?: (percent: number) => void;
  onPrevChapter?: () => void;
  onNextChapter?: () => void;
  onOpenSettings?: () => void;
  /** 点"目录"：跳转到独立的目录页（`ReaderCatalogPage`） */
  onOpenCatalog?: () => void;
  /** 点"夜间"：切换**整个 app** 的深浅色（见 `ThemeApplier`） */
  onToggleNight?: () => void;

  @State private draggingPercent: number = -1;

  private displayPercent(): number {
    return this.draggingPercent < 0 ? this.percent : this.draggingPercent;
  }

  /**
   * **上一行**（上一章/下一章）的文字字号。
   *
   * ⚠️ 只给"上一章 / 下一章"用 —— 它们是本栏的**主操作**，
   * 与顶栏"返回"同字号（`AppTheme.FONT_BAR_TEXT`，用户要求过对应）。
   * 下面那行次级导航（目录/夜间/设置）用 `LABEL_FONT_SIZE`，比它小两号。
   *
   * ⚠️ **不再由正文字号推导**（原实现是 `baseFontSize - SIZE_STEP`）：
   * 栏内是 UI 控件，正文调到 30 时把菜单栏一起撑大只会挤占阅读区。
   */
  private fontSize(): number {
    return AppTheme.FONT_BAR_TEXT;
  }

  build() {
    // 行间距从 6 收到 4：整体更紧凑一点（用户要求"整体变小一点点"）
    Column({ space: 4 }) {
      // 上一章 / 进度条 / 下一章 同一行：相邻章切换是最常用的动作，
      // 放在进度条两端，拇指点左右两侧都能够到。
      Row() {
        // ⚠️ 两个按钮内联写死，不抽带参 @Builder 复用：
        // 设计文档第 15 条 —— 同一个 build() 里把带参 @Builder 调多次，参数会串位。
        Text('上一章')
          .fontSize(this.fontSize())
          .fontColor(this.hasPrev ? this.theme.text : this.theme.secondary)
          .opacity(this.hasPrev ? 1 : 0.4)
          // 上下内边距 6 → 4：与"整体变小"一致，同时保留可点热区
          .padding({ top: 4, bottom: 4, left: 2, right: 10 })
          .onClick(() => {
            // 置灰只是体验层，规则层要自己判断：见设计文档第 29 条
            if (this.hasPrev && this.onPrevChapter !== undefined) {
              this.onPrevChapter();
            }
          })

        Slider({
          value: this.displayPercent() * 100,
          min: 0,
          max: 100,
          step: 1
        })
          .selectedColor(this.theme.text)
          .trackColor(this.theme.secondary)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              // 松手才跳章
              this.draggingPercent = -1;
              if (this.onJump !== undefined) {
                this.onJump(value / 100);
              }
            } else {
              // 拖动中只改显示
              this.draggingPercent = value / 100;
            }
          })

        Text('下一章')
          .fontSize(this.fontSize())
          .fontColor(this.hasNext ? this.theme.text : this.theme.secondary)
          .opacity(this.hasNext ? 1 : 0.4)
          .padding({ top: 4, bottom: 4, left: 10, right: 2 })
          .onClick(() => {
            if (this.hasNext && this.onNextChapter !== undefined) {
              this.onNextChapter();
            }
          })
      }
      .width('100%')

      /**
       * 第二行：目录 / 夜间 / 设置，**等分三块**，每块 = 图标 + 文字。
       *
       * ⚠️ 三个都用 `layoutWeight(1)` 而不是各自写宽度：
       * 等分由容器算，改字号/加语言时不会出现"某一块被文字撑宽、其余被挤窄"。
       * `Column` 的默认水平对齐就是居中，图标与文字自然对齐；
       * 点击热区覆盖整块（不是只有图标/文字可点）。
       *
       * ⚠️ 三块**内联写死**，不抽成带参 `@Builder`：
       * 设计文档第 15/41 条 —— 带参 `@Builder` 在同一处 `build()` 里调多次会串位。
       * 这里三块的图标、文字与回调都不同，正是最容易串位的场景。
       */
      Row() {
        // ① 目录
        Column({ space: ICON_LABEL_GAP }) {
          Image($r('app.media.contents'))
            .width(ICON_SIZE)
            .height(ICON_SIZE)
            // 图标染色：跟随阅读页主题的前景色
            .fillColor(this.theme.text)
            .objectFit(ImageFit.Contain)
          Text('目录')
            .fontSize(LABEL_FONT_SIZE)
            .fontColor(this.theme.text)
            // 显式声明常规字重：三块必须完全一致，不靠"默认值恰好相同"
            .fontWeight(FontWeight.Normal)
        }
        .layoutWeight(1)
        .padding({ top: 2, bottom: 2 })
        .onClick(() => {
          if (this.onOpenCatalog !== undefined) {
            this.onOpenCatalog();
          }
        })

        // ② 夜间 / 日间：切换**整个 app** 的深浅色。
        //
        // ⚠️ 与"设置"里的背景主题**不是一回事**（用户明确指出的区别）：
        //  - 本按钮 → 应用级深浅色，走系统 `setColorMode`，
        //    颜色来自 `resources/base|dark/element/color.json`；
        //  - 设置里的"背景" → 只改**阅读页正文背景**
        //    （浅色/羊皮纸/护眼/夜间四选一）。
        // 两者各管各的，互不冲突。
        //
        // ⚠️ **图标与文案都要反映"点下去会变成什么"，而不是当前状态**：
        // 当前是日间 → 显示月亮 + "夜间"（点了变夜间）；
        // 当前是夜间 → 显示太阳 + "日间"（点了回日间）。
        // 这正是用户要求的语义，也是切换类按钮的通用做法 ——
        // 显示"当前状态"会让人以为那是状态指示而不是按钮。
        //
        // ⚠️ **颜色与字重与另两块完全一致**（用户要求"正常一点"）：
        // 早先这里用 `theme.secondary`（灰）表示"未激活"，看着发浅、
        // 像被禁用；再叠一个 Medium 字重更显得三块不齐。
        // 现在三块统一 `theme.text` + Normal —— 当前处于哪种模式
        // 由**图标**（月亮/太阳）和文案表达，不需要靠颜色区分。
        Column({ space: ICON_LABEL_GAP }) {
          Image(this.appDarkMode ? $r('app.media.light') : $r('app.media.dark'))
            .width(ICON_SIZE)
            .height(ICON_SIZE)
            .fillColor(this.theme.text)
            .objectFit(ImageFit.Contain)
          Text(this.appDarkMode ? '日间' : '夜间')
            .fontSize(LABEL_FONT_SIZE)
            .fontColor(this.theme.text)
            .fontWeight(FontWeight.Normal)
        }
        .layoutWeight(1)
        .padding({ top: 2, bottom: 2 })
        .onClick(() => {
          if (this.onToggleNight !== undefined) {
            this.onToggleNight();
          }
        })

        // ③ 设置
        Column({ space: ICON_LABEL_GAP }) {
          Image($r('app.media.settings'))
            .width(ICON_SIZE)
            .height(ICON_SIZE)
            .fillColor(this.theme.text)
            .objectFit(ImageFit.Contain)
          Text('设置')
            .fontSize(LABEL_FONT_SIZE)
            .fontColor(this.theme.text)
            .fontWeight(FontWeight.Normal)
        }
        .layoutWeight(1)
        .padding({ top: 2, bottom: 2 })
        .onClick(() => {
          if (this.onOpenSettings !== undefined) {
            this.onOpenSettings();
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    /**
     * 左右与顶部留常规内边距；**底部额外叠加安全区高度**。
     *
     * ⚠️ 本栏要**盖住**常驻底栏（从屏幕底部升起），所以它必须自己把
     * 手势条那一段也涂上色。否则它下方会露出常驻底栏或页面底色，
     * 看起来像"菜单栏没铺到底"。
     *
     * 上下内边距一路收紧（8/12 → 6/10 → 4/8），配合图标 22→18、
     * 标签字号 16→14：整栏明显矮了一截（用户要求"整体变小"）。
     */
    .padding({
      left: 16,
      right: 16,
      top: 4,
      bottom: 8 + Math.max(0, this.safeAreaBottom)
    })
    /**
     * ⚠️ 背景必须**不透明**：本栏是覆盖在正文与常驻底栏之上的，
     * 用半透明的 `theme.barBg` 会让下层文字透出来（实测观感很乱）。
     *
     * 这也与本栏的定位一致 —— 它是"从底部升起的操作面板"，
     * 而不是"浮在正文上的轻量工具条"。顶栏仍可用半透明（它只压住一行标题）。
     */
    .backgroundColor(this.theme.bg)
  }
}
