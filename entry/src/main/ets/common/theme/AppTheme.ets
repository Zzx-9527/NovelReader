import { AppConstants } from '../constants/AppConstants';

/**
 * 颜色令牌：**全部走 `$r()` 资源引用，绝不写 hex 字面量**。
 *
 * 为什么这一层必须存在：
 *  - `$r('app.color.x')` 是资源引用，系统会在 `resources/base/` 与 `resources/dark/`
 *    之间自动切换 —— 这是深色模式能生效的**唯一途径**；
 *  - 页面里写 `'#3B6FE0'` 这样的字面量，深色模式下永远不会变。
 *
 * ⚠️ 自 API 18 起 `getContext()` 已废弃，因此本类只用 `$r()`（它在任何位置都可用），
 *    不依赖 Context，也不需要初始化。
 *
 * ⚠️ 不要在这里写 `static readonly X: string = '#xxx'` ——
 *    类型是 `string` 就等于绕过了资源系统，深色模式会失效。
 */
export class AppColor {
  // ------------------------------------------------- 点缀色（主题色，**小面积**）
  /**
   * 点缀色：**只用于图标、进度条、角标、当前项高亮**这类小面积元素。
   *
   * ⚠️ 它**不是**"品牌主色"，不要拿它铺按钮底色或大色块。
   *
   * 为什么要有这条纪律（本项目实测的设计决策）：
   * 早先版本把品牌色铺在「导入 / 继续 / 重试」按钮、选中的分组标签、
   * 以及**每一个封面占位块**上 —— 结果整屏都在喊，一屏 6~9 个封面
   * 全被染成同一个蓝，看起来像花屏，主题色反而失去了"点睛"的作用。
   *
   * 现在改成分工：**大色块一律中性（`primary`），颜色只留给小面积（本令牌）**。
   * 需要"强调一个按钮"时用 `primary`（近黑/近白），不要用 `accent`。
   */
  static readonly accent: Resource = $r('app.color.accent');

  // ------------------------------------------- 中性填充（按钮 / 选中标签）
  /**
   * 中性填充色：**按钮底、选中标签底**这类需要"实心强调"的大色块。
   *
   * ⚠️ 它是"近黑"（浅色模式）与"近白"（深色模式），不是纯黑纯白 ——
   * 纯黑在 OLED 上过硬、纯白在整屏时发晃，各退一步观感更稳。
   *
   * ⚠️ 用它做底时**必须**同时把前景设成 `onPrimary`：
   * `Button` 的默认字色是白色，深色模式下 `primary` 本身接近白色，
   * 不显式设字色就会出现"白底白字"直接看不见。
   */
  static readonly primary: Resource = $r('app.color.primary');
  /** `primary` 之上的文字/图标（浅色下近白、深色下近黑） */
  static readonly onPrimary: Resource = $r('app.color.on_primary');

  // ------------------------------------------------------------ 封面占位
  /**
   * 封面占位块底色 / 首字色。
   *
   * ⚠️ 刻意**中性**、不用点缀色：一屏要同时出现 6~9 个封面，
   * 若都染成主题色，整片网格会糊成一块同色，反而看不出书名。
   * 接入真实 EPUB 封面后这两项只作为"图未就绪"的兜底。
   */
  static readonly coverBg: Resource = $r('app.color.cover_bg');
  static readonly coverText: Resource = $r('app.color.cover_text');

  // ---------------------------------------------------------------- 背景
  static readonly bgPage: Resource = $r('app.color.bg_page');
  static readonly bgCard: Resource = $r('app.color.bg_card');
  static readonly mask: Resource = $r('app.color.mask');
  /**
   * 压在**深色遮罩之上**的文字/图标色。
   *
   * ⚠️ 不能复用 `textPrimary`：遮罩（`mask`）在**两种模式下都是黑的**，
   * 而 `textPrimary` 在深色模式下是近白、浅色模式下是近黑 ——
   * 浅色模式下用它就变成"黑底黑字"。遮罩上的字必须**恒定浅色**。
   */
  static readonly onScrim: Resource = $r('app.color.on_scrim');

  // ---------------------------------------------------------------- 文字
  static readonly textPrimary: Resource = $r('app.color.text_primary');
  static readonly textSecondary: Resource = $r('app.color.text_secondary');
  static readonly textHint: Resource = $r('app.color.text_hint');

  // ---------------------------------------------------------------- 其他
  static readonly divider: Resource = $r('app.color.divider');
  static readonly danger: Resource = $r('app.color.danger');
  static readonly success: Resource = $r('app.color.success');

  // ---------------------------------------------------------------- 启动相关
  /**
   * 启动窗口背景与启动页背景**共用同一个令牌**。
   *
   * ⚠️ 这不是偷懒：`module.json5` 的 `startWindowBackground` 和启动页的
   * `.backgroundColor()` 必须是同一个资源名，否则改了一个忘了另一个，
   * 冷启动时会在"系统启动窗口 → 启动页"这一步**闪一次颜色**。
   */
  static readonly splashBg: Resource = $r('app.color.splash_bg');
}

/**
 * 只能以 `string` 传色的场景专用常量。
 *
 * ⚠️ 存在的唯一理由：`promptAction.showActionMenu()` 的 `Button.color`
 * 声明类型是 `string`（`@ohos.promptAction.d.ts`），**不接受 `Resource`**。
 * 而 `AppColor` 全部是 `Resource`，塞进去直接编译失败。
 *
 * 代价：这些弹窗的颜色**不跟随深浅模式**。可接受 ——
 * ActionMenu 是系统组件，样式本来就以系统为准，我们只是给标题/危险项上色。
 *
 * 判据：**只要某个 API 声明要求 `string`，就走这里；否则一律用 `AppColor`。**
 */
export class AppColorLiteral {
  /** 与 `app.color.text_primary` 的浅色档一致（ActionMenu 只收 string） */
  static readonly textPrimary: string = '#1F1F1F';
  /**
   * 点缀色的字面量形式（值与 `app.color.accent` 的浅色档一致）。
   *
   * ⚠️ 改 `base/element/color.json` 的 `accent` 时，**这里要一起改** ——
   * 两处不同步的话，ActionMenu 里的"开始阅读"会和界面上的点缀色对不上。
   * 之所以无法避免这份重复：`Button.color` 只收 `string`，资源引用塞不进去。
   */
  static readonly accent: string = '#35597F';
  static readonly danger: string = '#B4432F';
}

/**
 * 尺寸与字号令牌。
 *
 * 这些是纯数值，不涉及深浅模式，因此保持 `number` 类型。
 */
export class AppTheme {
  // ---------------------------------------------------------------- 间距
  static readonly GAP_S: number = 8;
  static readonly GAP_M: number = 12;
  static readonly GAP_L: number = 16;
  static readonly PAGE_PADDING: number = 16;

  // ---------------------------------------------------------------- 圆角
  static readonly CARD_RADIUS: number = 12;
  static readonly ITEM_RADIUS: number = 8;
  static readonly CHIP_RADIUS: number = 14;

  // ---------------------------------------------------------------- 字号
  static readonly FONT_TITLE: number = 20;
  static readonly FONT_SUBTITLE: number = 16;
  static readonly FONT_BODY: number = 14;
  static readonly FONT_CAPTION: number = 12;
  static readonly FONT_SLOGAN: number = 13;
  /**
   * 阅读页**栏内操作文字**的统一字号（顶栏"‹ 返回"、菜单底栏"目录/夜间/设置"…）。
   *
   * ⚠️ 抽成常量的理由：用户要求"底部状态栏与顶部返回的字体对应"。
   * 若两处各写一个 16，将来调其中一个，两栏就不对应了 ——
   * 而"对应"这件事必须由**同一个来源**保证，不能靠两处巧合相等
   * （设计文档第 28 条：同一逻辑两处实现，改一处必忘另一处）。
   *
   * ⚠️ 它**不跟随正文字号**：栏内操作文字是 UI 控件，不是阅读内容。
   * 正文调大时栏内文字跟着涨会把菜单栏撑得很大（且底部栏还要盖住常驻栏）。
   */
  static readonly FONT_BAR_TEXT: number = 16;

  // ---------------------------------------------------------------- 布局
  /** 书架网格列数 */
  static readonly SHELF_COLUMNS: number = 3;
  /** 封面高宽比（高 : 宽 = 4 : 3） */
  static readonly COVER_ASPECT: number = 4 / 3;
  /** 底部导航栏高度 */
  static readonly TAB_BAR_HEIGHT: number = 48;
  /** 顶栏高度 */
  static readonly TOP_BAR_HEIGHT: number = 52;
  /**
   * 阅读页**常驻**底栏的**文字区**高度（左章节名 / 右进度）。
   *
   * ⚠️ 不含底部安全区 —— 手势条那部分由**实测值**（`safeAreaBottom`）动态叠加：
   * 底栏总高 = `READER_FOOTER_HEIGHT + safeAreaBottom`（见 `ReaderPage.footerTotalHeight()`）。
   * 把安全区写死在这里是不行的：各机型手势条高度不同（有的还没有）。
   *
   * 这个值必须被**两处**同时使用，且含义一致：
   *   1. 底栏自身的文字区高度；
   *   2. 菜单栏整体上移的量（否则菜单栏会压住常驻栏）。
   * 两处不一致就会重叠或留缝 —— 所以只留这一个常量，别处不要再写数字。
   */
  static readonly READER_FOOTER_HEIGHT: number = 30;
  /** 启动页最少停留时长（避免一闪而过） */
  static readonly SPLASH_MIN_MS: number = 450;
  /** 启动页硬超时（预热挂住也要跳走） */
  static readonly SPLASH_TIMEOUT_MS: number = 3000;
  /**
   * 阅读页字号的一档（"大一号 / 小一号" = 正文 ± 2）。
   *
   * 为什么用相对量而不是写死字号：正文字号由用户设置（默认 18，可调到 30），
   * 章节标题若固定 20vp，用户把正文调到 28 时标题反而比正文小，层级就反了；
   * 底栏同理。所有"比正文大/小一号"的地方都从这里取。
   */
  static readonly SIZE_STEP: number = 2;

  // ============================================================ 「纸与线」装饰层
  /**
   * 这一组常量是本次界面重构（"纸与线"）的全部装饰参数。
   *
   * ⚠️ **它们不含任何颜色** —— 颜色一律来自 `AppColor`（资源令牌），
   * 因为颜色必须跟随深浅模式。这里只有**尺寸与不透明度**，
   * 所以放在 `AppTheme` 而不是 `AppColor` 里。
   *
   * ⚠️ 集中在这里的理由与正文排版参数一样（设计文档第 28 条）：
   * 发丝线出现在十几处，各处写一个 `1` 或 `0.28` 就再也无法统一调整。
   */

  /**
   * 发丝线粗细（vp）。全项目所有"分隔线"的唯一来源。
   *
   * ⚠️ 恒为 1：在 3x 屏上就是 3 个物理像素，正好是"印刷里的一条细线"的量感。
   * 调成 2 会立刻变成"框"，整个界面会从"纸"滑向"表格"。
   */
  static readonly HAIRLINE: number = 1;

  // ---------------------------------------------------------------- 封面
  /** 封面左侧书脊宽度（vp） */
  static readonly COVER_SPINE_W: number = 3;
  /**
   * 书脊不透明度。
   *
   * ⚠️ 这是"点缀色只用于小面积"这条既有纪律的关键：一屏 9 个封面，
   * 每个 3vp 宽，合计着色面积约 27vp² —— 远小于一个按钮底。
   * 取 1.0 会让网格里出现 9 条硬边蓝线，取 0.55 才是"书的厚度"。
   */
  static readonly COVER_SPINE_ALPHA: number = 0.55;
  /** 封面首字下方题花线宽度（vp） */
  static readonly COVER_RULE_W: number = 18;
  /** 题花线不透明度（色用 `cover_text`） */
  static readonly COVER_RULE_ALPHA: number = 0.45;
  /** 封面底部进度**轨道**不透明度（有进度时才画，色用 `cover_text`） */
  static readonly COVER_TRACK_ALPHA: number = 0.22;

  // ---------------------------------------------------------------- 进度发丝
  /**
   * 进度发丝线粗细（vp）。
   *
   * ⚠️ 从原来的 4 降到 2：4vp 在浅色卡片上是一条"色块"，
   * 2vp 才像书页上的一条标线。这一点点差别决定了卡片是"工具"还是"纸张"。
   */
  static readonly RAIL_H: number = 2;
  /** 进度末梢圆点直径（vp），标记"我正停在这里" */
  static readonly RAIL_DOT: number = 6;

  // ---------------------------------------------------------------- 阅读页
  /** 章节标题下题花短线宽度（vp）。全书只此一处装饰 */
  static readonly READER_RULE_W: number = 24;
  /**
   * 阅读页浮层分隔线的不透明度。
   *
   * ⚠️ 原来是**满强度**的 `theme.secondary`，在浅色主题下那条线比正文还重，
   * 看起来像输入框的边框。降到 0.30 才是"分隔"的语义。
   */
  static readonly READER_RULE_ALPHA: number = 0.30;
  /** 阅读页两行菜单之间的分隔线（比浮层边界更轻） */
  static readonly READER_INNER_RULE_ALPHA: number = 0.20;

  // ---------------------------------------------------------------- 列表
  /**
   * 列表模式"缩进发丝线"的左起点（vp）。
   *
   * ⚠️ 必须等于 `封面 48 + 间距 12 + 内边距 12`：
   * 线从**文字列**开始，封面那一列保持连续 —— 这是印刷里"缩进线"的做法，
   * 通栏线会把每一行切成独立的卡片，正好是我们要去掉的观感。
   * 改了封面尺寸或间距，这里要一起改。
   */
  static readonly LIST_RULE_INSET: number = 72;

  // ---------------------------------------------------------------- 底部导航
  /** 选中页签上方的点缀短横：宽 / 高（vp） */
  static readonly TAB_MARK_W: number = 18;
  static readonly TAB_MARK_H: number = 2;

  // ---------------------------------------------------------------- 其他
  /**
   * 胶囊类小控件高度（vp）。
   *
   * 圆角复用既有的 `CHIP_RADIUS`(14)：30 高配 14 圆角即视觉上的全圆角，
   * 再单独加一个 15 的常量只会多一个要同步的数字。
   */
  static readonly CHIP_H: number = 30;
  /** 空状态几何标记边长（vp） */
  static readonly MARK_SIZE: number = 92;

  // ================================================================ 字距
  /**
   * 标题类文字的字距（vp）。
   *
   * ⚠️ 这一组是"书卷气"的**主要来源**，而不是衬线字体 ——
   * 原因见 `AppFont` 的说明（手机上取不到中文衬线）。
   * 中文正文加字距会显得松散，但**标题加一点点**会立刻有"排印"的味道，
   * 且与字体、设备、系统版本全部无关，是确定性收益。
   */
  static readonly TRACK_TITLE: number = 0.5;
  /** 书名 / 分组名的字距（比标题更克制，因为它出现在密集网格里） */
  static readonly TRACK_NAME: number = 0.2;
  /** 封面首字的字距 */
  static readonly TRACK_COVER: number = 1;
  /** 「静读」wordmark 的字距（大字号下才敢用这么大的值） */
  static readonly TRACK_WORDMARK: number = 4;
  /** 阅读页章节标题的字距 */
  static readonly TRACK_CHAPTER: number = 0.5;

  // ============================================================ 划线底纹
  /**
   * 划线底纹的样式（`Span.textBackgroundStyle` 的参数）。
   *
   * ⚠️ 存在的唯一理由是 **ArkTS 的类型要求**：本项目的 linter 启用了
   * `arkts-no-untyped-obj-literals`，而 `build()` 里**不能声明局部变量** ——
   * 于是无法在渲染处"先把字面量赋给带类型的变量再传进去"
   * （这是本项目在 `buildTextEditMenu` 里用过的标准写法）。
   * 把对象提到这里、用确定类型的静态字段承载，是唯一干净的解法。
   *
   * ⚠️ 颜色取 `AppConstants.HIGHLIGHT_DEFAULT_COLOR`，与写库时用的是**同一个常量**：
   * 两处各写一个色值，将来改颜色就会"库里存 A、界面画 B"，而且不报错。
   *
   * ⚠️ 这里**不跟随** `ReaderTheme`：划线的暖黄是"记号笔"的颜色，
   * 四种阅读底色（浅色/羊皮纸/护眼/夜间）下都必须一样 ——
   * 它标记的是"我划过这里"，不是界面装饰。夜间模式下暖黄底 + 浅灰字
   * 依然可读（这正是选暖黄而不是深色的原因）。
   */
  static highlightSpanStyle(): TextBackgroundStyle {
    const style: TextBackgroundStyle = {
      color: AppConstants.HIGHLIGHT_DEFAULT_COLOR,
      radius: AppConstants.HIGHLIGHT_RADIUS
    };
    return style;
  }
}

/**
 * 阅读页配色。
 *
 * ⚠️ 这里**刻意不用资源令牌**：阅读页的配色是**用户选择的四套方案**
 * （浅色/羊皮纸/护眼/夜间），不是"跟随系统深浅模式"。
 * 若走令牌，系统切深色会和用户的选择打架 —— 用户在护眼绿下切系统深色，
 * 阅读页会突然变黑，那是不对的。
 *
 * 因此这里返回普通 class 实例，颜色是确定的 hex 字符串 ——
 * 这是全项目**唯一**允许写 hex 的地方，理由是它不参与系统主题切换。
 */
export class ReaderTheme {
  bg: string = '#FFFFFF';
  text: string = '#1A1A1A';
  secondary: string = '#888888';
  /**
   * 半透明底色（alpha `F2`）。
   *
   * ⚠️ **不要用它做任何"浮层栏"的背景**（顶栏/菜单底栏/设置面板/常驻底栏）——
   * 这些栏弹出时下方压着正文，半透明会让正文文字透出来，看起来像渲染错误。
   * 它们统一用**不透明**的 `bg`（本项目实测踩过：顶栏半透明、底栏不透明，
   * 屏幕上出现"上面透、下面不透"的割裂感）。
   *
   * 现在仅用于**不透明容器内部**的小色块（如设置面板里未选中的字号胶囊），
   * 那里下方是纯色面板、不存在文字透出的问题。
   */
  barBg: string = '#F2FFFFFF';

  /**
   * 解析出最终生效的阅读页配色。
   *
   * ⚠️ `appDark` 是**应用级夜间模式**（`ThemeApplier`），它**优先于**
   * `theme`（用户在"设置 → 背景"里选的阅读页配色）：
   * 全局夜间打开时阅读页也必须变深色，否则会出现
   * "书架是黑的、正文还是白的"这种割裂（用户明确要求全局一致）。
   *
   * 反过来，全局夜间关闭时阅读页完全跟随用户自己选的 `theme`
   * （浅色/羊皮纸/护眼/夜间四选一 —— 那是**只影响阅读页**的独立设置）。
   *
   * ⚠️ 默认值 `false` 是**刻意**的：设置面板里那四个色块预览
   * （`SettingsPanel.buildThemeRow`）调用的正是 `ReaderTheme.of(name)`，
   * 它们必须显示各自主题的真实配色，不能被全局夜间改写。
   *
   * ⚠️ 这里是"全局夜间覆盖阅读页"的**唯一实现点**，别处不要再判一次 ——
   * 否则以后加一个阅读页就会漏一处（设计文档第 28 条）。
   */
  static of(theme: string, appDark: boolean = false): ReaderTheme {
    const t = new ReaderTheme();
    // 全局夜间优先
    const effective: string = appDark ? 'dark' : theme;
    if (effective === 'dark') {
      t.bg = '#111111';
      // 正文用 #C8C8C8 而不是纯白：纯白在暗背景上对比过强，长时间阅读刺眼
      t.text = '#C8C8C8';
      t.secondary = '#777777';
      t.barBg = '#F2202020';
    } else if (effective === 'sepia') {
      t.bg = '#F5EDE0';
      t.text = '#3E3226';
      t.secondary = '#8A7A66';
      t.barBg = '#F2F5EDE0';
    } else if (effective === 'eye_care') {
      // 低饱和绿：饱和度高的绿反而更累眼
      t.bg = '#CCE8CF';
      t.text = '#2B3A2E';
      t.secondary = '#5F7563';
      t.barBg = '#F2CCE8CF';
    }
    return t;
  }

  /** 主题标识列表，设置面板按此顺序渲染 */
  static readonly THEMES: string[] = ['light', 'sepia', 'eye_care', 'dark'];

  static labelOf(theme: string): string {
    if (theme === 'dark') {
      return '夜间';
    }
    if (theme === 'sepia') {
      return '羊皮纸';
    }
    if (theme === 'eye_care') {
      return '护眼';
    }
    return '浅色';
  }
}
