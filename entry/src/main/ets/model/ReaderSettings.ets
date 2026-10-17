import { AppConstants } from '../common/constants/AppConstants';

/**
 * 阅读设置快照（纯数据，不含 IO）。
 * 由 data/service/SettingsService 读写 Preferences 并填充本对象，
 * ViewModel 只读这份对象，不直接接触 preferences。
 */
export class ReaderSettings {
  // ---------------------------------------------------------------- 排版
  fontSize: number = AppConstants.DEFAULT_FONT_SIZE;
  /**
   * 正文字体族名。
   *
   * ⚠️ 取值 `'system'` 是**哨兵值**，表示"不指定、用系统默认字体"，
   * 它**不是**一个真实的字体族名。真正要传给文字引擎的字符串必须经
   * `resolveFontFamily()` 解析 —— 直接把它塞给 `Text.fontFamily()`
   * 或 `measureTextSize()` 属于传一个不存在的字体名。
   */
  fontFamily: string = 'system';
  lineHeight: number = AppConstants.DEFAULT_LINE_HEIGHT;
  /**
   * ⚠️ **段间距字段已删除**（原 `paragraphSpacing`）。
   *
   * 原因不是"不重要"，而是**做不出可用的连续值**：ArkUI 没有段落间距属性
   * （无 `leadingMargin` / `paragraphSpacing`，`Span` 也没有 margin/padding），
   * 段距只能靠"插入整数个空行"实现 ⇒ 滑块上只有 `round(ps × 2)` 个
   * 有效档位（0.25 一档），中间全是**死区**（用户实测：
   * "0~0.2 不变、0.2~0.7 不变"，就是量化造成的）。
   *
   * 所以段落之间的空隙**回到由原文空行承担**：它自己占 1 行，
   * 简单、可见，不需要也不该有一个调不动的旋钮。
   *
   * ⚠️ 与 `firstLineIndent` 的区别值得注意：那个字段**保留**了，
   * 因为它仍在参与分页与渲染；而段距**不再参与任何计算**，
   * 留着它只会让人以为还有这个设置。**判据：字段是否还有消费者。**
   */
  pageMargin: number = AppConstants.DEFAULT_PAGE_MARGIN;
  letterSpacing: number = 0;
  /**
   * 段首缩进（字）。
   *
   * ⚠️ **已不是可调设置**（用户要求移除）：中文正文的段首缩进几乎总是两个字，
   * 做一个永远不会被动的滑块只是占地方。现在它**固定为默认值**，
   * 但仍参与三处计算（分页的每行字数、渲染补缩进、`layoutKey` 指纹），
   * 所以字段**必须保留** —— 删掉它这三处就都失去依据了。
   *
   * ⚠️ 也**不再从 Preferences 读/写**（见 `SettingsService`）：
   * 它现在是个常量，落盘一个永远不会变的值没有意义，
   * 还会让"改了哪里、为什么没生效"变得难查。
   */
  firstLineIndent: number = AppConstants.DEFAULT_FIRST_LINE_INDENT;

  /**
   * 系统默认字体族名（`'system'` 哨兵解析后的结果）。
   *
   * ⚠️ 写成一个**确定的名字**而不是"不设置"，是为了让**分页测量**与
   * **正文渲染**请求到同一个字体：两边都请求 `HarmonyOS Sans`，
   * 即使某台设备上没有这个字体，两边也会以**同样的方式**回退到系统默认 ——
   * 结果依然一致。反过来，一边显式请求、另一边完全不设置，回退路径
   * 就可能不同，量出的高度与渲染高度会悄悄错开（正是本 bug 的成因）。
   */
  static readonly SYSTEM_FONT: string = 'HarmonyOS Sans';

  /**
   * 把设置里存的值解析成**真正传给文字引擎**的字体族名。
   *
   * ⚠️ 这是全项目**唯一**允许做这个翻译的地方。分页测量
   * （`ReaderPage.setMeasureFn`）与三处正文渲染（章节标题 / 滚动正文 /
   * 分页正文）**必须**都走这里，否则就回到"测量与渲染不同源"的老问题：
   * 量的时候按 A 字体算每行几个字、渲染时用 B 字体画，字宽一变就会
   * 溢出或末行被裁（设计文档反复强调的铁律）。
   *
   * 判据：**任何要进 `Text` 或 `measureTextSize` 的字体名，都从这里出。**
   */
  static resolveFontFamily(raw: string): string {
    const value: string = raw.trim();
    // 空串与哨兵都表示"用系统默认"
    return (value.length === 0 || value === 'system')
      ? ReaderSettings.SYSTEM_FONT
      : value;
  }

  // ---------------------------------------------------------------- 显示
  /**
   * 'scroll' | 'page' | 'slide' | 'cover'
   *
   * ⚠️ `slide`（平移翻页）：内容与 `page` 完全同源（同一套 breaks/renderAt），
   * 只是渲染外套一层 Swiper 提供平移动画；跨章翻页由页面在动画结束时
   * 调 `nextPage()/prevPage()` 并把 Swiper 复位到中间槽位。
   * `cover`（仿真翻页）尚未实现，设置面板刻意不提供该选项。
   */
  pageMode: string = 'scroll';
  /** 'light' | 'warm' | 'dark' | 'sepia' | 'eye_care' */
  theme: string = 'light';
  /**
   * 屏幕亮度：**-1 表示跟随系统**，0~1 为手动值。
   *
   * ⚠️ `-1` 不是"无效值"而是**明确的语义**：切回它时必须调用
   * `setWindowBrightness(-1)` 把控制权交回系统。跳过调用的话，
   * 用户从"手动 0.3"切回"跟随系统"屏幕会一直停在 0.3。
   */
  brightness: number = -1;
  /**
   * 音量键翻页（仅阅读页生效，默认关）。
   *
   * ⚠️ 默认关闭而不是开：音量键翻页会**改变系统音量**的直觉预期 ——
   * 用户在别的 App 里按音量键是调音量，这里突然变成翻页，
   * 首次接触是惊吓而不是惊喜。让用户主动打开它，比替他决定更稳妥。
   */
  volumeKeyPage: boolean = false;
  /** 阅读时保持屏幕常亮（默认开：阅读场景下屏幕熄灭几乎总是打扰） */
  keepScreenOn: boolean = true;
  /**
   * 阅读时隐藏状态栏（默认关）。
   *
   * ⚠️ 只影响阅读页正文态：菜单/面板弹出时页面会**自动恢复**状态栏
   * （顶栏的返回按钮必须可见可点），这不是用户要管的细节，
   * 所以设置文案只写"阅读时隐藏"，恢复行为由页面自动处理。
   */
  hideStatusBar: boolean = false;

  // ---------------------------------------------------------------- 书架
  gridMode: boolean = true;
  /** 'last_read' | 'added' | 'title' */
  bookSort: string = 'last_read';

  // ---------------------------------------------------------------- TTS
  ttsSpeed: number = 1.0;
  ttsVoice: string = '';
  ttsTimerMinutes: number = 0;
}
