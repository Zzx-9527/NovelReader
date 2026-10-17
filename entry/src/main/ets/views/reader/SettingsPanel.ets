import { AppColor, AppTheme, ReaderTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { ReaderSettings } from '../../model/ReaderSettings';
import { AppConstants } from '../../common/constants/AppConstants';

/**
 * 翻页方式：三种（滚动 / 左右翻页 / 平移翻页）。
 *
 * ⚠️ `cover`（仿真翻页）**尚未实现**，刻意不放出来 ——
 * 放出来就是"选了没反应"的假选项。等动画做完再补第 4 段。
 */
const PAGE_MODES: string[] = ['scroll', 'page', 'slide'];

/** 翻页方式的展示名 */
function pageModeLabel(mode: string): string {
  if (mode === 'page') {
    return '左右翻页';
  }
  if (mode === 'slide') {
    return '平移翻页';
  }
  return '上下滚动';
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
  /**
   * 阅读页配色。
   *
   * ⚠️ **必须是 `@Prop`**：普通成员只在创建时快照，
   * 面板打开期间切"夜间"（或改背景）不会同步 —— 与顶栏/底栏同一个坑。
   */
  @Prop theme: ReaderTheme = new ReaderTheme();
  /**
   * 底部安全区（手势条）高度，vp。
   *
   * ⚠️ 本面板从屏幕底部升起、要**盖住**常驻底栏，所以得自己把
   * 手势条那一段也涂上色；否则面板下方会露出常驻底栏或页面底色。
   * 由父组件传入（它从 `AppStorage` 拿得到，本组件拿不到）。
   */
  @Prop safeAreaBottom: number = 0;
  /** 任一项变化后回调整份设置；页面负责落盘与重排 */
  onChange?: (next: ReaderSettings) => void;
  /** 点「完成」收起面板（bindSheet 的 onDisappear 也会兜底同步状态） */
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
    /**
     * ⚠️ `paragraphSpacing` 与 `firstLineIndent` **都不参与派生**：
     * 两者都已不是可调设置（段距整个移除、缩进固定为 2）。
     * `derive()` 出来的新对象用模型默认值，与原值相同 —— 无副作用。
     * 在这里复制它们反而会让人以为"这个面板还能改这两项"。
     */
    next.pageMargin = s.pageMargin;
    next.letterSpacing = s.letterSpacing;
    /**
     * ⚠️ `firstLineIndent` **不参与派生**：它已不是可调设置
     * （固定为 `AppConstants.DEFAULT_FIRST_LINE_INDENT`）。
     * 若在这里复制一份，反而会让人以为它还能被这个面板改动。
     * `derive()` 出来的新对象会用模型默认值，与原值相同 —— 无副作用。
     */
    next.pageMode = s.pageMode;
    next.theme = s.theme;
    next.brightness = s.brightness;
    next.keepScreenOn = s.keepScreenOn;
    next.volumeKeyPage = s.volumeKeyPage;
    next.hideStatusBar = s.hideStatusBar;
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
    Column() {
      /**
       * 抓手：34×4 的圆角短横，居中。
       *
       * ⚠️ 效果稿里它是"这是一张从底部升起的纸"的第一个信号；
       * 画在面板内部顶部即可，不需要额外的浮层结构。
       */
      Row()
        .width(34)
        .height(4)
        .borderRadius(2)
        .backgroundColor(this.theme.secondary)
        .opacity(0.4)
        .margin({ bottom: AppTheme.GAP_M })

      this.buildHeader()

      Scroll() {
        Column({ space: AppTheme.GAP_L }) {
          this.buildFontSizeRow()
          this.buildLineHeightRow()
          /**
           * ⚠️ **首行缩进已移除**（用户要求）：中文正文的段首缩进几乎
           * 总是两个字，做一个永远不会被动的滑块只是占地方。
           * 机制仍在（`ReaderSettings.firstLineIndent` 固定为 2），
           * 只是不再开放调节。
           *
           * ⚠️ **段间距也已移除**（用户要求）：ArkUI 没有"段落间距"属性
           * （无 `leadingMargin` / `paragraphSpacing`，`Span` 也没有 margin），
           * 段距只能靠"插入整数个空行"实现 —— 于是滑块上只有
           * `round(ps × 2)` 个有效档位（0.25 一档），中间全是**死区**
           * （用户实测："0~0.2 不变、0.2~0.7 不变"，就是这个量化造成的）。
           *
           * 现在间距**回到由原文空行决定**：这本书每段之间本就有空行，
           * 它自己就是最好的段落间距，不需要再叠一个调不动的旋钮。
           */
          this.buildLetterSpacingRow()
          this.buildPageMarginRow()
          this.buildPageModeRow()
          this.buildThemeRow()
          /**
           * ⚠️ 亮度排在排版项之后：开头是"调正文"（字号/行距/字距/边距），
           * 那是用户最常动的；亮度是**一次配好就不再动**的项，放最后不挡路。
           *
           * ⚠️ 它是**窗口级**设置（作用于整个阅读界面，不改排版），
           * 与上面"改一下就重排正文"的项性质不同 —— 分组排列本身
           * 就在表达这个区别。
           */
          this.buildBrightnessRow()
          this.buildKeepScreenOnRow()
          this.buildHideStatusBarRow()
          this.buildVolumeKeyRow()
        }
        .width('100%')
        .padding({ bottom: AppTheme.GAP_L })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    /**
     * 左右留常规内边距；顶部收窄（抓手已承担"顶部呼吸"）；
     * **底部额外叠加安全区高度** —— 本面板要盖住常驻底栏，
     * 必须自己把手势条那一段也涂上色。
     */
    .padding({
      left: 18,
      right: 18,
      top: 10,
      bottom: 12 + Math.max(0, this.safeAreaBottom)
    })
    /**
     * ⚠️ 背景必须**不透明**（`theme.bg`，不用半透明的 `theme.barBg`）：
     * 本面板是覆盖在正文与常驻底栏之上的，半透明会让下层文字透出来。
     *
     * ⚠️ 顶角圆角加大到 18：效果稿里它是"一张纸的顶盖"，
     * 12 的圆角读起来还像"一块方板的斜角"。
     */
    .backgroundColor(this.theme.bg)
    .borderRadius({ topLeft: 18, topRight: 18 })
    /**
     * ⚠️ 必须裁切：面板内 Scroll 的内容是直角的，不裁的话
     * 滚动内容会从 18vp 圆角的外面画出来（顶角处露出一块方角）——
     * 这正是"圆角设了但看起来没有圆角"的原因。
     */
    .clip(true)
  }

  @Builder
  buildHeader() {
    /**
     * 标题 + 「完成」按钮（用户要求：用"完成"替代系统自带的 ✕ 白圈）。
     *
     * ⚠️ 关闭路径：点「完成」、点蒙层、下滑手势三条 ——
     * ✕ 已由 `showCloseButton: false` 关掉，标题右侧这颗「完成」
     * 是面板内唯一显式的关闭动作（朱色，标题行唯一的彩色）。
     */
    Row() {
      Text('阅读设置')
        .fontSize(AppTheme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        // 标题落衬线（探测到才有）—— 与全 app 的题字同一套语汇
        .fontFamily(AppFont.titleFamily())
        .letterSpacing(1.5)
        .fontColor(this.theme.text)
        .layoutWeight(1)

      Text('完成')
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontColor(AppColor.accent)
        .letterSpacing(1)
        .padding({ left: 12, right: 4, top: 8, bottom: 8 })
        .onClick(() => {
          if (this.onClose !== undefined) {
            this.onClose();
          }
        })
    }
    .width('100%')
    .margin({ bottom: 4 })
  }

  // ------------------------------------------------------------ 字号

  @Builder
  buildFontSizeRow() {
    Column({ space: AppTheme.GAP_S }) {
      /**
       * 标签与数值**同一行**（用户要求）：「字号 …… 20」，
       * 进度条独占下一行 —— 一项设置两行、四项的左缘全部对齐。
       */
      Row() {
        Text('字号')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .layoutWeight(1)
        Text(`${this.settings.fontSize}`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')

      /**
       * 字号：**滑块**（原来是 8 个离散档位 + A−/A+ 按钮）。
       *
       * ⚠️ 松手才提交（`SliderChangeMode.End` / `Click`），与其它滑块一致：
       * 字号每变 1vp 都要清分页缓存 + 全章重排，拖动过程中连续提交
       * 会把主线程压满、界面直接卡住。
       *
       * ⚠️ 范围与步长走 `AppConstants.MIN/MAX_FONT_SIZE`、`FONT_SIZE_STEP`：
       * 上下限与原档位一致（14~30），只是把粒度从"8 档"放开到"每 1vp"。
       *
       * ⚠️ **不带 `A−` / `A+` 按钮**（用户要求去掉）：
       * 滑块已经能覆盖 14~30 的每一档，两个按钮既占宽度又让这一行显得拥挤；
       * 而且它们与滑块共用同一份范围，属于"同一能力两个入口"。
       * 判据：**滑块的粒度已经够细时，就不要在旁边再放步进按钮。**
       */
      Slider({
        value: this.settings.fontSize,
        min: AppConstants.MIN_FONT_SIZE,
        max: AppConstants.MAX_FONT_SIZE,
        step: AppConstants.FONT_SIZE_STEP
      })
        .selectedColor(this.theme.text)
        .trackColor(this.theme.secondary)
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            const next: ReaderSettings = this.derive();
            next.fontSize = Math.round(value);
            this.emit(next);
          }
        })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 行距

  @Builder
  buildLineHeightRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('行距')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .layoutWeight(1)
        Text(this.lineHeightLabel())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
          .fontFeature(AppFont.TABULAR)
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

  // ------------------------------------------------------------ 字间距

  /**
   * 字间距。
   *
   * ⚠️ 它不只是"看着松一点"：**每行能放多少字直接由它决定**
   * （`charWidth = fontSize × 0.92 + letterSpacing`），
   * 调大后每行字数变少、页数变多，分页会跟着重算 —— 这是正确行为，不是 bug。
   */
  @Builder
  buildLetterSpacingRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('字间距')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .layoutWeight(1)
        Text(`${this.settings.letterSpacing.toFixed(1)} vp`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')

      Slider({
        value: this.settings.letterSpacing * 10,
        min: AppConstants.MIN_LETTER_SPACING * 10,
        max: AppConstants.MAX_LETTER_SPACING * 10,
        step: 5
      })
        .selectedColor(this.theme.text)
        .trackColor(this.theme.secondary)
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          // 与其他滑块一致：松手才提交（拖动中每帧都重排会卡）
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            const next: ReaderSettings = this.derive();
            next.letterSpacing = Math.round(value) / 10;
            this.emit(next);
          }
        })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 页边距

  /**
   * 左右页边距。
   *
   * 渲染端（正文 `Text` 的 padding）与分页端（可用宽度减去 `pageMargin × 2`）
   * **必须用同一个值**，否则每行字数会算错、页面末尾被裁。
   */
  @Builder
  buildPageMarginRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('页边距')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .layoutWeight(1)
        Text(`${Math.round(this.settings.pageMargin)} vp`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')

      Slider({
        value: this.settings.pageMargin,
        min: AppConstants.MIN_PAGE_MARGIN,
        max: AppConstants.MAX_PAGE_MARGIN,
        step: 2
      })
        .selectedColor(this.theme.text)
        .trackColor(this.theme.secondary)
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            const next: ReaderSettings = this.derive();
            next.pageMargin = value;
            this.emit(next);
          }
        })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 翻页方式

  /**
   * 翻页方式：**分段选择器**（segmented control）。
   *
   * 与"两颗内容宽度的胶囊"的区别，都是刻意的：
   *  - **等宽平分**：两段各占一半，选中态是一个**滑块的槽**，
   *    而不是"哪颗胶囊被点亮"。用户一眼看出这是"二选一"，不是两个按钮；
   *  - **外框 + 内填充**：外层一条 `secondary` 描边把两段圈成**一个控件**，
   *    内层用 `theme.bg` 反色表示选中项。原来的两颗独立胶囊
   *    看起来像两个并列动作，用户得读文案才知道是互斥的。
   *
   * ⚠️ 只提供已实现的三种，理由见文件顶部的 `PAGE_MODES` 注释。
   * 四段等分由 `layoutWeight(1)` 保证，段宽不随文案长短漂移。
   */
  @Builder
  buildPageModeRow() {
    /**
     * 标题独占一行、选择器下一行（用户要求改回）——
     * 与滑块项的「标题行 + 控件行」节奏一致，面板纵向节奏统一。
     */
    Column({ space: AppTheme.GAP_S }) {
      Text('翻页方式')
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontColor(this.theme.text)
        .width('100%')

      Row() {
        ForEach(PAGE_MODES, (mode: string) => {
          Text(pageModeLabel(mode))
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(this.settings.pageMode === mode
              ? this.theme.bg
              : this.theme.secondary)
            .backgroundColor(this.settings.pageMode === mode
              ? this.theme.text
              : Color.Transparent)
            // ⚠️ `layoutWeight(1)` 而不是各自写宽度：等分由容器算，
            // 改文案/换语言时不会出现"某一段被文字撑宽、另一段被挤窄"
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .borderRadius(AppTheme.CHIP_RADIUS)
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
      .padding(3)
      // 外框：把两段圈成一个控件；槽底用 `barBg`（比面板底深半档）
      .border({ width: 1, color: this.theme.secondary })
      .borderRadius(AppTheme.CHIP_RADIUS + 3)
      .backgroundColor(this.theme.barBg)
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 主题

  @Builder
  buildThemeRow() {
    /**
     * 「背景」标题已删（用户要求）：五个色块自带"这是背景选择"的形，
     * 每块下方还有主题名（浅色/暖白/…），文字标签是第三次重复。
     */
    Row({ space: AppTheme.GAP_S }) {
        ForEach(ReaderTheme.THEMES, (name: string) => {
          Column({ space: 5 }) {
            /**
             * 色块用该主题自己的 bg/text，所见即所得；**等宽放大**到 44 高
             * （原来 40 固定宽、一行四个时右侧留白）——
             * `layoutWeight(1)` 让五块平分整行，加一档主题也不用重排版。
             *
             * ⚠️ 选中态：**朱色描边** + **右下角折角**（效果稿）——
             * 折角画在色块内部右下角（`Stack` 叠一个小的角三角形块），
             * 颜色用点缀色。粗细差 0.5vp 的描边在五块里几乎不可辨，
             * 一道朱色边 + 一枚折角才是"这个被选中了"的确定表达。
             */
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
                  width: this.settings.theme === name ? 1.5 : 1,
                  color: this.settings.theme === name
                    ? AppColor.accent
                    : this.theme.secondary
                })

              // 折角：右下角一枚小三角（选中时才画）
              if (this.settings.theme === name) {
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
              .fontColor(this.settings.theme === name
                ? AppColor.accent
                : this.theme.secondary)
              .maxLines(1)
              .textAlign(TextAlign.Center)
              .width('100%')
          }
          .layoutWeight(1)
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
  }

  // ------------------------------------------------------------ 亮度

  /**
   * 屏幕亮度。
   *
   * ⚠️ 滑块范围是 **0~100**（整数），但设置里存的是 **-1 或 0~1** ——
   * 转换只在本方法里做一次。
   *
   * ## 为什么是「两个胶囊 + 一个滑块」而不是「一个胶囊 + 一个滑块」
   *
   * 上一版是"一颗「跟随系统」胶囊 + 一个滑块，且跟随系统时滑块被禁用"，
   * 那是个**死循环式交互**（用户实测反馈"点不动、拖不了"）：
   *  - 默认值就是 `-1`（跟随系统）⇒ 滑块一进来就是禁用态；
   *  - 而唯一能解除禁用的，是那颗**看起来正表示当前状态**的胶囊 ——
   *    它长得像"状态指示"而不是"开关"，用户根本不会想到去点它。
   *
   * 现在改成**两个并列胶囊（跟随系统 / 手动）**：二选一的关系一眼可见，
   * 而且「手动」是一个非常明确的动作承诺 —— 选了它滑块就能拖。
   * 判据：**当"可操作性"取决于另一个控件的状态时，那个控件必须长得像开关**。
   *
   * ⚠️ 拖动中也只改显示、松手才提交（与本面板其它滑块一致）：
   * 每次改动都会走一遍 `updateSettings` → 重排正文，
   * 拖动过程中连续提交会把主线程压满。
   */
  @Builder
  buildBrightnessRow() {
    Column({ space: AppTheme.GAP_S }) {
      /**
       * 标题独占一行（用户要求改回，与「翻页方式」同一节奏）：
       * 「亮度」标题行 → 选择器行 → 滑块行（滑块位置不动）。
       * 手动档时的百分比数值缀在标题右侧。
       */
      Row() {
        Text('亮度')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .layoutWeight(1)

        Text(this.brightnessLabel())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')

      /**
       * 亮度的来源：**分段选择器**（跟随系统 / 手动）。
       *
       * 与「翻页方式」用**完全同一套**写法（等宽分段 + 外框），
       * 本面板里"二选一"因此只有一种表达。
       *
       * ⚠️ 绝不能退回"一颗胶囊 + 禁用滑块"：默认就是跟随系统，
       * 那样滑块一进来就是禁用态，而唯一能解锁的控件**长得像状态指示**，
       * 用户不会想到去点它（用户实测反馈过"点不动、拖不了"）。
       * 判据：**当"可操作性"取决于另一个控件的状态时，那个控件必须长得像开关。**
       */
      Row() {
        Text('跟随系统')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.isManualBrightness() ? this.theme.secondary : this.theme.bg)
          .backgroundColor(this.isManualBrightness() ? Color.Transparent : this.theme.text)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(AppTheme.CHIP_RADIUS)
          .onClick(() => {
            if (!this.isManualBrightness()) {
              return;
            }
            const next: ReaderSettings = this.derive();
            /**
             * ⚠️ 显式写 -1，而不是"留空/跳过"：切回跟随系统必须把这个值
             * 真的传下去，页面才会调 `setWindowBrightness(-1)` 交还控制权。
             * 跳过的话屏幕会一直停在手动亮度上（见 `ReaderSettings.brightness`）。
             */
            next.brightness = -1;
            this.emit(next);
          })

        Text('手动')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.isManualBrightness() ? this.theme.bg : this.theme.secondary)
          .backgroundColor(this.isManualBrightness() ? this.theme.text : Color.Transparent)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(AppTheme.CHIP_RADIUS)
          .onClick(() => {
            if (this.isManualBrightness()) {
              return;
            }
            const next: ReaderSettings = this.derive();
            /**
             * ⚠️ 从「跟随系统」切到「手动」必须给一个**确定的手动值**（0.5），
             * 不能沿用 -1 —— 那会让滑块拿到一个非法值、拖动手感错乱。
             * 0.5 是不改变观感的中间档：用户切过去、屏幕不会突然变亮或变暗。
             */
            next.brightness = AppConstants.DEFAULT_MANUAL_BRIGHTNESS;
            this.emit(next);
          })
      }
      .width('100%')
      .padding(3)
      // 外框：把两段圈成一个控件（与「翻页方式」同一套写法）
      .border({ width: 1, color: this.theme.secondary })
      .borderRadius(AppTheme.CHIP_RADIUS + 3)
      .backgroundColor(this.theme.barBg)

      Slider({
        /**
         * ⚠️ 非手动档时滑块停在 50% 只是**显示**，此时它被禁用、不生效。
         * 之所以还画出来（而不是隐藏）：让"亮度可调"这件事始终可见，
         * 用户才知道有这回事、也看得出"切到手动就能拖"。
         */
        value: this.isManualBrightness()
          ? this.settings.brightness * 100
          : AppConstants.DEFAULT_MANUAL_BRIGHTNESS * 100,
        min: 0,
        max: 100,
        step: 1
      })
        .selectedColor(this.theme.text)
        .trackColor(this.theme.secondary)
        .width('100%')
        .enabled(this.isManualBrightness())
        .opacity(this.isManualBrightness() ? 1 : 0.4)
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            const next: ReaderSettings = this.derive();
            next.brightness = Math.round(value) / 100;
            this.emit(next);
          }
        })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 亮度

  /** 亮度是否处于「手动」档（即不是 -1 跟随系统） */
  private isManualBrightness(): boolean {
    return this.settings.brightness >= 0;
  }

  /**
   * 亮度标签：跟随系统时不显示百分比。
   *
   * ⚠️ 「跟随系统」档下显示一个百分比是**错的**：那个数字不生效，
   * 用户会以为当前亮度就是它。所以这一档**返回空串**，
   * 由旁边的胶囊表达状态（那个词已经由「跟随系统」胶囊承担了，
   * 这里再写一遍就是同一信息两处显示）。
   */
  private brightnessLabel(): string {
    if (!this.isManualBrightness()) {
      return '';
    }
    return `${Math.round(this.settings.brightness * 100)}%`;
  }

  // ------------------------------------------------------------ 常亮 / 音量键

  /**
   * 「保持常亮」开关行。
   *
   * ⚠️ 与亮度同属**窗口级**设置（不重排正文），所以排在亮度之后；
   * 样式沿用分段选择器（开 / 关），与「翻页方式」同一套写法 ——
   * 本面板里"二选一"只有一种表达。
   */
  @Builder
  buildKeepScreenOnRow() {    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('保持常亮')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .layoutWeight(1)

        Text(this.settings.keepScreenOn ? '阅读时不熄屏' : '跟随系统')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
      }
      .width('100%')

      Row() {
        Text('开')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.settings.keepScreenOn ? this.theme.bg : this.theme.secondary)
          .backgroundColor(this.settings.keepScreenOn ? this.theme.text : Color.Transparent)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(AppTheme.CHIP_RADIUS)
          .onClick(() => {
            if (this.settings.keepScreenOn) {
              return;
            }
            const next: ReaderSettings = this.derive();
            next.keepScreenOn = true;
            this.emit(next);
          })

        Text('关')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.settings.keepScreenOn ? this.theme.secondary : this.theme.bg)
          .backgroundColor(this.settings.keepScreenOn ? Color.Transparent : this.theme.text)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(AppTheme.CHIP_RADIUS)
          .onClick(() => {
            if (!this.settings.keepScreenOn) {
              return;
            }
            const next: ReaderSettings = this.derive();
            next.keepScreenOn = false;
            this.emit(next);
          })
      }
      .width('100%')
      .padding(3)
      .border({ width: 1, color: this.theme.secondary })
      .borderRadius(AppTheme.CHIP_RADIUS + 3)
      .backgroundColor(this.theme.barBg)
    }
    .width('100%')
  }

  /**
   * 「隐藏状态栏」开关行。
   *
   * ⚠️ 文案只写"阅读时隐藏"，**不提恢复**：菜单/面板弹出时状态栏自动
   * 恢复是页面的自动行为（顶栏"返回"必须可见可点），不是用户要管的细节 ——
   * 写出来只会让人以为要自己来回切换。
   *
   * ⚠️ 与亮度/常亮同属窗口级设置，排在同一组（排版项之后）。
   */
  @Builder
  buildHideStatusBarRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('隐藏状态栏')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .layoutWeight(1)

        Text(this.settings.hideStatusBar ? '已开启' : '已关闭')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
      }
      .width('100%')

      Row() {
        Text('开')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.settings.hideStatusBar ? this.theme.bg : this.theme.secondary)
          .backgroundColor(this.settings.hideStatusBar ? this.theme.text : Color.Transparent)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(AppTheme.CHIP_RADIUS)
          .onClick(() => {
            if (this.settings.hideStatusBar) {
              return;
            }
            const next: ReaderSettings = this.derive();
            next.hideStatusBar = true;
            this.emit(next);
          })

        Text('关')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.settings.hideStatusBar ? this.theme.secondary : this.theme.bg)
          .backgroundColor(this.settings.hideStatusBar ? Color.Transparent : this.theme.text)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(AppTheme.CHIP_RADIUS)
          .onClick(() => {
            if (!this.settings.hideStatusBar) {
              return;
            }
            const next: ReaderSettings = this.derive();
            next.hideStatusBar = false;
            this.emit(next);
          })
      }
      .width('100%')
      .padding(3)
      .border({ width: 1, color: this.theme.secondary })
      .borderRadius(AppTheme.CHIP_RADIUS + 3)
      .backgroundColor(this.theme.barBg)
    }
    .width('100%')
  }

  /**
   * 「音量键翻页」开关行。
   *
   * ⚠️ 标题旁必须带一句说明"音量同时会变"：按键无法阻止系统调音量
   * （没有 API 撤销），不告知的话用户第一次按会觉得"坏了"。
   * 把行为边界写在界面上，比让用户踩一遍再抱怨便宜。
   */
  @Builder
  buildVolumeKeyRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('音量键翻页')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .layoutWeight(1)

        Text(this.settings.volumeKeyPage ? '已开启' : '已关闭')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
      }
      .width('100%')

      Text('音量+/- 上下翻页；按键仍会调整系统音量')
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(this.theme.secondary)
        .width('100%')

      Row() {
        Text('开')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.settings.volumeKeyPage ? this.theme.bg : this.theme.secondary)
          .backgroundColor(this.settings.volumeKeyPage ? this.theme.text : Color.Transparent)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(AppTheme.CHIP_RADIUS)
          .onClick(() => {
            if (this.settings.volumeKeyPage) {
              return;
            }
            const next: ReaderSettings = this.derive();
            next.volumeKeyPage = true;
            this.emit(next);
          })

        Text('关')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.settings.volumeKeyPage ? this.theme.secondary : this.theme.bg)
          .backgroundColor(this.settings.volumeKeyPage ? Color.Transparent : this.theme.text)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(AppTheme.CHIP_RADIUS)
          .onClick(() => {
            if (!this.settings.volumeKeyPage) {
              return;
            }
            const next: ReaderSettings = this.derive();
            next.volumeKeyPage = false;
            this.emit(next);
          })
      }
      .width('100%')
      .padding(3)
      .border({ width: 1, color: this.theme.secondary })
      .borderRadius(AppTheme.CHIP_RADIUS + 3)
      .backgroundColor(this.theme.barBg)
    }
    .width('100%')
  }
}
