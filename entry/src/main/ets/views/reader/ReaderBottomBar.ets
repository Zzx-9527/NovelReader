import { AppTheme, ReaderTheme } from '../../common/theme/AppTheme';

/**
 * 阅读页**菜单底栏**（点屏幕中间才出现，负责"操作"）。
 *
 * 版面（从上到下）：
 * ```
 *                                                     设置
 * [上一章] ============进度条============ [下一章]
 * ```
 *
 * ⚠️ 本栏**只放操作**，不放任何"告知类"信息 ——
 * 章节名、页码、全书百分比全部由阅读页的**常驻底栏**
 * （`ReaderPage.buildReaderFooter`）承担，它永远可见。
 * 本栏只在呼出菜单时出现，重复显示同一份信息毫无意义、还挤占操作空间。
 *
 * ⚠️ 展示值必须用 `@Prop`：普通成员只在组件**创建时**取一次快照，
 * 父组件后续的状态变化不会同步进来 —— 表现为"拖动进度条后数字又弹回去"。
 *
 * 拖动过程中只更新本地状态（draggingPercent），松手才真正跳章（SliderChangeMode.End），
 * 避免拖动时反复触发重排。
 */
@Component
export struct ReaderBottomBar {
  theme: ReaderTheme = new ReaderTheme();
  /** 正文字号：栏内文字统一比它小一号（`AppTheme.SIZE_STEP`） */
  @Prop baseFontSize: number = 18;
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
  onJump?: (percent: number) => void;
  onPrevChapter?: () => void;
  onNextChapter?: () => void;
  onOpenSettings?: () => void;

  @State private draggingPercent: number = -1;

  private displayPercent(): number {
    return this.draggingPercent < 0 ? this.percent : this.draggingPercent;
  }

  /** 栏内文字字号：比正文小一号 */
  private fontSize(): number {
    return Math.max(10, this.baseFontSize - AppTheme.SIZE_STEP);
  }

  build() {
    Column({ space: 6 }) {
      /**
       * 第一行：只有"设置"。
       *
       * ⚠️ 这里**既不显示章节名/百分比，也不显示页码** —— 它们全都由阅读页的
       * **常驻底栏**（`ReaderPage.buildReaderFooter`）承担了：
       * 左=章节名，右=`页码 百分比`。本栏只在呼出菜单时出现，
       * 重复显示同一份信息没有意义，还挤占操作空间。
       *
       * 于是本栏的职责很纯粹：**只放操作**（设置 / 进度条 / 上下章）。
       */
      Row({ space: 8 }) {
        Blank()

        Text('设置')
          .fontSize(this.fontSize())
          .fontColor(this.theme.text)
          .padding({ left: 8, top: 2, bottom: 2 })
          .onClick(() => {
            if (this.onOpenSettings !== undefined) {
              this.onOpenSettings();
            }
          })
      }
      .width('100%')

      // 上一章 / 进度条 / 下一章 同一行：相邻章切换是最常用的动作，
      // 放在进度条两端，拇指点左右两侧都能够到（放下面一行就得上下移拇指）。
      Row() {
        // ⚠️ 两个按钮内联写死，不抽带参 @Builder 复用：
        // 设计文档第 15 条 —— 同一个 build() 里把带参 @Builder 调多次，参数会串位。
        Text('上一章')
          .fontSize(this.fontSize())
          .fontColor(this.hasPrev ? this.theme.text : this.theme.secondary)
          .opacity(this.hasPrev ? 1 : 0.4)
          .padding({ top: 6, bottom: 6, left: 2, right: 10 })
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
          .padding({ top: 6, bottom: 6, left: 10, right: 2 })
          .onClick(() => {
            if (this.hasNext && this.onNextChapter !== undefined) {
              this.onNextChapter();
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
     */
    .padding({
      left: 16,
      right: 16,
      top: 8,
      bottom: 12 + Math.max(0, this.safeAreaBottom)
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
