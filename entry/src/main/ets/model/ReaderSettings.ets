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
  paragraphSpacing: number = AppConstants.DEFAULT_PARAGRAPH_SPACING;
  pageMargin: number = AppConstants.DEFAULT_PAGE_MARGIN;
  letterSpacing: number = 0;
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
  /** 'scroll' | 'page' | 'cover' */
  pageMode: string = 'scroll';
  /** 'light' | 'dark' | 'sepia' | 'eye_care' */
  theme: string = 'light';
  /** 自定义背景色，空串表示跟随主题 */
  bgColor: string = '';
  keepScreenOn: boolean = false;
  hideStatusBar: boolean = true;
  volumeKeyPage: boolean = false;
  /** -1 表示跟随系统 */
  brightness: number = -1;

  // ---------------------------------------------------------------- 书架
  gridMode: boolean = true;
  /** 'last_read' | 'added' | 'title' */
  bookSort: string = 'last_read';

  // ---------------------------------------------------------------- TTS
  ttsSpeed: number = 1.0;
  ttsVoice: string = '';
  ttsTimerMinutes: number = 0;
}
