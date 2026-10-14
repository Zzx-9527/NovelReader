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
  // ---------------------------------------------------------------- 品牌
  /** 主色：按钮、选中态、进度条 */
  static readonly brand: Resource = $r('app.color.brand');
  /** 主色浅底：封面占位块、chip 选中底 */
  static readonly brandContainer: Resource = $r('app.color.brand_container');
  /** 主色之上的文字 */
  static readonly onBrand: Resource = $r('app.color.on_brand');

  // ---------------------------------------------------------------- 背景
  static readonly bgPage: Resource = $r('app.color.bg_page');
  static readonly bgCard: Resource = $r('app.color.bg_card');
  static readonly mask: Resource = $r('app.color.mask');

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
  static readonly textPrimary: string = '#1D1D1F';
  static readonly brand: string = '#2F5D8C';
  static readonly danger: string = '#C7463A';
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
