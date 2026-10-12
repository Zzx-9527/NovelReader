import { AppTheme, ReaderTheme } from '../../common/theme/AppTheme';
import { ReaderSettings } from '../../model/ReaderSettings';
import { AppConstants } from '../../common/constants/AppConstants';

/** 字号档位（vp）。上下限刻意留窄：14 以下读不动，30 以上一屏没几个字 */
const FONT_SIZES: number[] = [14, 16, 18, 20, 22, 24, 26, 30];

/**
 * 翻页方式：只放已实现的两种。
 *
 * ⚠️ `cover`（仿真/覆盖翻页）虽然在 `ReaderSettings` 的注释里列着，
 * 但翻页动画并没有实现 —— 放出来就是"选了没反应"的假选项。
 * 等动画做完再补。
 */
const PAGE_MODES: string[] = ['scroll', 'page'];

/** 翻页方式的展示名 */
function pageModeLabel(mode: string): string {
  return mode === 'page' ? '左右翻页' : '上下滚动';
}

/**
 * 阅读设置面板（从阅读页底部弹出的浮层）。
 *
 * 两条设计约定：
 *
 * 1. **就地生效，没有"确定/取消"**。
 *    调节字号、行距的时候，用户要的是"看着正文调"——
 *    改完再点确定，等于让他盲调。所以每动一下就回调 `onChange`，
 *    由页面转给 `ReaderViewModel.updateSettings()` 立刻重排。
 *
 * 2. **配色走 ReaderTheme，不走 AppColor**。
 *    它属于阅读页的一部分（和顶栏/底栏同一层语义），
 *    用户在羊皮纸/夜间主题下打开设置，面板必须跟着变 ——
 *    用 `AppColor` 的话它会在夜间主题下变成一块白板。
 *
 * ⚠️ `settings` 用 `@Prop` 接收整份设置对象。
 *    它是普通 class（非 `@Observed`），`@Prop` 会做**深拷贝** ——
 *    正是想要的：面板改动不会顺着共享引用把阅读页的状态悄悄改掉，
 *    必须经 `onChange` 显式交回去。
 */
@Component
export struct SettingsPanel {
  /** 当前设置快照（由阅读页持有并传进来） */
  @Prop settings: ReaderSettings = new ReaderSettings();
  theme: ReaderTheme = new ReaderTheme();
  /** 任一项变化后回调整份设置；页面负责落盘与重排 */
  onChange?: (next: ReaderSettings) => void;
  onClose?: () => void;

  /**
   * 复制一份再改。
   *
   * 为什么不直接改 `this.settings`：`@Prop` 虽然是深拷贝，
   * 但把它原地改掉会让"面板里的值"和"外部真正的设置"看着一样、实际脱钩，
   * 页面对不上账时极难排查。每次改动都从当前值派生一份新的，
   * 语义明确：**基于当前设置产生一份新设置**。
   *
   * ⚠️ 这里刻意显式逐字段拷贝，而不是想办法"整体克隆"：
   * ArkTS 没有展开运算符，`ReaderSettings` 也是普通 class
   * （`JSON.parse(JSON.stringify())` 对 class 实例不可靠，参见文档第 23 条）。
   * 代价是加字段时要来这儿补一行 —— 所以 `ReaderSettings` 一旦扩容，
   * **必须同时改这里**，否则新字段会在用户每次调设置时被悄悄重置成默认值。
   */
  private derive(): ReaderSettings {
    const next = new ReaderSettings();
    const s: ReaderSettings = this.settings;
    next.fontSize = s.fontSize;
    next.fontFamily = s.fontFamily;
    next.lineHeight = s.lineHeight;
    next.paragraphSpacing = s.paragraphSpacing;
    next.pageMargin = s.pageMargin;
    next.letterSpacing = s.letterSpacing;
    next.firstLineIndent = s.firstLineIndent;
    next.pageMode = s.pageMode;
    next.theme = s.theme;
    next.bgColor = s.bgColor;
    next.keepScreenOn = s.keepScreenOn;
    next.hideStatusBar = s.hideStatusBar;
    next.volumeKeyPage = s.volumeKeyPage;
    next.brightness = s.brightness;
    next.gridMode = s.gridMode;
    next.bookSort = s.bookSort;
    next.ttsSpeed = s.ttsSpeed;
    next.ttsVoice = s.ttsVoice;
    next.ttsTimerMinutes = s.ttsTimerMinutes;
    return next;
  }

  private emit(next: ReaderSettings): void {
    if (this.onChange !== undefined) {
      this.onChange(next);
    }
  }

  build() {
    Column({ space: AppTheme.GAP_L }) {
      this.buildHeader()

      Scroll() {
        Column({ space: AppTheme.GAP_L }) {
          this.buildFontSizeRow()
          this.buildLineHeightRow()
          this.buildParagraphSpacingRow()
          this.buildFirstLineIndentRow()
          this.buildPageModeRow()
          this.buildThemeRow()
        }
        .width('100%')
        .padding({ bottom: AppTheme.GAP_L })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    .backgroundColor(this.theme.barBg)
    .borderRadius({ topLeft: AppTheme.CARD_RADIUS, topRight: AppTheme.CARD_RADIUS })
  }

  @Builder
  buildHeader() {
    Row() {
      Text('阅读设置')
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.text)
        .layoutWeight(1)

      Text('完成')
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(this.theme.text)
        .padding({ left: 12, right: 4, top: 4, bottom: 4 })
        .onClick(() => {
          if (this.onClose !== undefined) {
            this.onClose();
          }
        })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 字号

  @Builder
  buildFontSizeRow() {
    Column({ space: AppTheme.GAP_S }) {
      // ⚠️ 这些行标题与按钮一律**内联**，不抽成带参 @Builder：
      // 设计文档第 15 条 —— 同一个 build() 里把带参 @Builder 调多次，参数会串位
      // （本面板行标题有 6 处、样式完全相同，最容易踩这个坑）。
      Row() {
        Text('字号')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(this.theme.text)
          .layoutWeight(1)
        Text(`${this.settings.fontSize}`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
      }
      .width('100%')

      // 用"档位 + A-/A+"而不是滑块：
      // 字号是离散档位，且每改一次都要重排，连续拖动只会疯狂重算。
      Row({ space: AppTheme.GAP_M }) {
        Text('A-')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(this.theme.text)
          .width(44)
          .height(32)
          .textAlign(TextAlign.Center)
          .borderRadius(AppTheme.ITEM_RADIUS)
          .backgroundColor(this.theme.bg)
          .onClick(() => {
            this.stepFontSize(-1);
          })

        Row({ space: 4 }) {
          ForEach(FONT_SIZES, (size: number) => {
            Text(`${size}`)
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(this.settings.fontSize === size
                ? this.theme.bg
                : this.theme.secondary)
              .backgroundColor(this.settings.fontSize === size
                ? this.theme.text
                : this.theme.barBg)
              .borderRadius(AppTheme.ITEM_RADIUS)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick(() => {
                const next: ReaderSettings = this.derive();
                next.fontSize = size;
                this.emit(next);
              })
          }, (size: number) => `${size}`)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.SpaceBetween)

        Text('A+')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .width(44)
          .height(32)
          .textAlign(TextAlign.Center)
          .borderRadius(AppTheme.ITEM_RADIUS)
          .backgroundColor(this.theme.bg)
          .onClick(() => {
            this.stepFontSize(1);
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  /** 按档位表步进，而不是 ±1vp：字号在档位之间跳，排版结果才可预期 */
  private stepFontSize(direction: number): void {
    const sizes: number[] = FONT_SIZES;
    const current: number = this.settings.fontSize;
    let index: number = 0;
    for (let i = 0; i < sizes.length; i++) {
      if (sizes[i] <= current) {
        index = i;
      }
    }
    const target: number = direction > 0
      ? Math.min(sizes.length - 1, index + 1)
      : Math.max(0, index - 1);
    if (sizes[target] === current) {
      return;
    }
    const next: ReaderSettings = this.derive();
    next.fontSize = sizes[target];
    this.emit(next);
  }

  // ------------------------------------------------------------ 行距

  @Builder
  buildLineHeightRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('行距')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(this.theme.text)
          .layoutWeight(1)
        Text(this.lineHeightLabel())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
      }
      .width('100%')

      Slider({
        value: this.settings.lineHeight * 10,
        min: AppConstants.MIN_LINE_HEIGHT * 10,
        max: AppConstants.MAX_LINE_HEIGHT * 10,
        step: 1
      })
        .selectedColor(this.theme.text)
        .trackColor(this.theme.secondary)
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          // 松手才重排：拖动过程中每一帧都重排会卡到没法用
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            const next: ReaderSettings = this.derive();
            next.lineHeight = Math.round(value) / 10;
            this.emit(next);
          }
        })
    }
    .width('100%')
  }

  private lineHeightLabel(): string {
    return this.settings.lineHeight.toFixed(1);
  }

  // ------------------------------------------------------------ 段距

  @Builder
  buildParagraphSpacingRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('段间距')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(this.theme.text)
          .layoutWeight(1)
        Text(this.settings.paragraphSpacing.toFixed(1))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
      }
      .width('100%')

      Slider({
        value: this.settings.paragraphSpacing * 10,
        min: 0,
        max: AppConstants.MAX_PARAGRAPH_SPACING * 10,
        step: 1
      })
        .selectedColor(this.theme.text)
        .trackColor(this.theme.secondary)
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            const next: ReaderSettings = this.derive();
            next.paragraphSpacing = Math.round(value) / 10;
            this.emit(next);
          }
        })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 首行缩进

  @Builder
  buildFirstLineIndentRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('首行缩进')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(this.theme.text)
          .layoutWeight(1)
        Text(`${this.settings.firstLineIndent.toFixed(1)} 字`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
      }
      .width('100%')

      Slider({
        value: this.settings.firstLineIndent * 10,
        min: 0,
        max: 40,
        step: 5
      })
        .selectedColor(this.theme.text)
        .trackColor(this.theme.secondary)
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            const next: ReaderSettings = this.derive();
            next.firstLineIndent = Math.round(value) / 10;
            this.emit(next);
          }
        })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 翻页方式

  /**
   * 只提供已实现的两种，理由见文件顶部的 `PAGE_MODES` 注释。
   */
  @Builder
  buildPageModeRow() {
    Column({ space: AppTheme.GAP_S }) {
      Text('翻页方式')
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(this.theme.text)
        .width('100%')
      Row({ space: AppTheme.GAP_S }) {
        ForEach(PAGE_MODES, (mode: string) => {
          Text(pageModeLabel(mode))
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(this.settings.pageMode === mode
              ? this.theme.bg
              : this.theme.text)
            .backgroundColor(this.settings.pageMode === mode
              ? this.theme.text
              : this.theme.bg)
            .borderRadius(AppTheme.CHIP_RADIUS)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .onClick(() => {
              if (this.settings.pageMode === mode) {
                return;
              }
              const next: ReaderSettings = this.derive();
              next.pageMode = mode;
              this.emit(next);
            })
        }, (mode: string) => mode)
      }
      .width('100%')
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 主题

  @Builder
  buildThemeRow() {
    Column({ space: AppTheme.GAP_S }) {
      Text('背景')
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(this.theme.text)
        .width('100%')
      Row({ space: AppTheme.GAP_S }) {
        ForEach(ReaderTheme.THEMES, (name: string) => {
          Column({ space: 4 }) {
            // 色块用该主题自己的 bg/text，所见即所得
            Text('文')
              .fontSize(AppTheme.FONT_BODY)
              .fontColor(ReaderTheme.of(name).text)
              .width(40)
              .height(40)
              .textAlign(TextAlign.Center)
              .backgroundColor(ReaderTheme.of(name).bg)
              .borderRadius(AppTheme.ITEM_RADIUS)
              .border({
                width: this.settings.theme === name ? 2 : 1,
                color: this.settings.theme === name ? this.theme.text : this.theme.secondary
              })
            Text(ReaderTheme.labelOf(name))
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(this.settings.theme === name
                ? this.theme.text
                : this.theme.secondary)
          }
          .onClick(() => {
            if (this.settings.theme === name) {
              return;
            }
            const next: ReaderSettings = this.derive();
            next.theme = name;
            this.emit(next);
          })
        }, (name: string) => name)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
  }
}
