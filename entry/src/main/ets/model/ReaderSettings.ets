import { AppConstants } from '../common/constants/AppConstants';

/**
 * 阅读设置快照（纯数据，不含 IO）。
 * 由 data/service/SettingsService 读写 Preferences 并填充本对象，
 * ViewModel 只读这份对象，不直接接触 preferences。
 */
export class ReaderSettings {
  // ---------------------------------------------------------------- 排版
  fontSize: number = AppConstants.DEFAULT_FONT_SIZE;
  fontFamily: string = 'system';
  lineHeight: number = AppConstants.DEFAULT_LINE_HEIGHT;
  paragraphSpacing: number = AppConstants.DEFAULT_PARAGRAPH_SPACING;
  pageMargin: number = AppConstants.DEFAULT_PAGE_MARGIN;
  letterSpacing: number = 0;
  firstLineIndent: number = AppConstants.DEFAULT_FIRST_LINE_INDENT;

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
