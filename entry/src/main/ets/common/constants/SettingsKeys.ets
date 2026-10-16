/**
 * Preferences 的 key 常量。
 * 全部 key 集中在此，禁止在业务代码里散落字符串字面量。
 * 详见 docs/小说阅读器设计文档.md 5.6。
 */
export const SETTINGS_STORE_NAME: string = 'reader_settings';

/** 当前设置结构版本 */
export const SETTINGS_SCHEMA_VERSION: number = 1;

export class SettingsKeys {
  /** 设置结构版本，用于设置项迁移 */
  static readonly SCHEMA_VERSION: string = 'schema_version';
  static readonly FIRST_LAUNCH_DONE: string = 'first_launch_done';

  // ---------------------------------------------------------------- 排版
  static readonly FONT_SIZE: string = 'font_size';
  static readonly FONT_FAMILY: string = 'font_family';
  static readonly LINE_HEIGHT: string = 'line_height';
  /**
   * ⚠️ 已废弃、**刻意保留**的键名：`paragraph_spacing`。
   *
   * 段距设置已整个移除（原因见 `SettingsPanel`：ArkUI 没有段落间距属性，
   * 段距只能插整数个空行 ⇒ 滑块上只有 0.25 一档有效、中间全是死区）。
   * 段落之间的空隙现在由**原文空行**承担。
   *
   * **不要删这一行、也不要复用这个名字**：老用户的 Preferences 里可能
   * 还留着这个键，将来拿它做别的设置会与历史数据撞车。
   */
  static readonly PARAGRAPH_SPACING_DEPRECATED: string = 'paragraph_spacing';
  static readonly PAGE_MARGIN: string = 'page_margin';
  static readonly LETTER_SPACING: string = 'letter_spacing';
  /**
   * ⚠️ 已废弃、**刻意保留**的键名：`first_line_indent`。
   *
   * 段首缩进已改成固定值（见 `AppConstants.DEFAULT_FIRST_LINE_INDENT`），
   * 不再读写。**但不要删这一行** —— 老用户的 Preferences 里可能还留着
   * 这个键，删掉常量只是让新代码不再引用它，不影响旧数据；
   * 保留注释是为了**下一个人知道"这个名字被用过"**，
   * 免得将来又拿它做别的设置，与历史数据撞车。
   */
  static readonly FIRST_LINE_INDENT_DEPRECATED: string = 'first_line_indent';

  // ---------------------------------------------------------------- 显示
  static readonly PAGE_MODE: string = 'page_mode';
  /**
   * **阅读页正文**背景方案：light / sepia / eye_care / dark。
   *
   * ⚠️ 与 `APP_THEME_MODE` 是两件事，别合并：
   * 本项只影响阅读页正文背景（用户选的护眼绿不该被系统深色覆盖）；
   * `APP_THEME_MODE` 控制整个 app 的深浅色。
   */
  static readonly THEME: string = 'theme';
  /**
   * **应用级**主题模式：0 跟随系统 / 1 浅色 / 2 夜间。
   *
   * 由菜单底栏的"夜间"按钮切换（见 `ThemeApplier`）。
   */
  static readonly APP_THEME_MODE: string = 'app_theme_mode';
  static readonly BRIGHTNESS: string = 'brightness';
  /**
   * 音量键翻页（仅阅读页生效）。
   *
   * ⚠️ 与文档 5.6 的旧 key 清单对不上：设计文档列过 `volume_key_page`，
   * 但代码里从未落地 —— 本次补全按同一命名写在这里。
   */
  static readonly VOLUME_KEY_PAGE: string = 'volume_key_page';
  /** 阅读时保持屏幕常亮 */
  static readonly KEEP_SCREEN_ON: string = 'keep_screen_on';
  /**
   * 阅读时隐藏状态栏（正文沉浸）。
   *
   * ⚠️ 只在阅读页**正文态**生效：菜单/设置面板弹出时自动恢复显示 ——
   * 顶栏的"返回"必须让用户看得见、点得着。
   */
  static readonly HIDE_STATUS_BAR: string = 'hide_status_bar';

  // ---------------------------------------------------------------- 书架
  static readonly GRID_MODE: string = 'grid_mode';
  static readonly BOOK_SORT: string = 'book_sort';

  // ---------------------------------------------------------------- TTS
  static readonly TTS_SPEED: string = 'tts_speed';
  static readonly TTS_VOICE: string = 'tts_voice';
  static readonly TTS_TIMER_MINUTES: string = 'tts_timer_minutes';
}
