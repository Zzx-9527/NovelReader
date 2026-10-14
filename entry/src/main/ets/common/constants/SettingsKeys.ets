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
  static readonly PARAGRAPH_SPACING: string = 'paragraph_spacing';
  static readonly PAGE_MARGIN: string = 'page_margin';
  static readonly LETTER_SPACING: string = 'letter_spacing';
  static readonly FIRST_LINE_INDENT: string = 'first_line_indent';

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
  static readonly BG_COLOR: string = 'bg_color';
  static readonly KEEP_SCREEN_ON: string = 'keep_screen_on';
  static readonly HIDE_STATUS_BAR: string = 'hide_status_bar';
  static readonly VOLUME_KEY_PAGE: string = 'volume_key_page';
  static readonly BRIGHTNESS: string = 'brightness';

  // ---------------------------------------------------------------- 书架
  static readonly GRID_MODE: string = 'grid_mode';
  static readonly BOOK_SORT: string = 'book_sort';

  // ---------------------------------------------------------------- TTS
  static readonly TTS_SPEED: string = 'tts_speed';
  static readonly TTS_VOICE: string = 'tts_voice';
  static readonly TTS_TIMER_MINUTES: string = 'tts_timer_minutes';
}
