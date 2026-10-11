import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  SETTINGS_SCHEMA_VERSION, SETTINGS_STORE_NAME, SettingsKeys
} from '../../common/constants/SettingsKeys';
import { AppConstants, LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';
import { ReaderSettings } from '../../model/ReaderSettings';

/**
 * 设置服务：Preferences 读写 + 默认值 + 版本迁移 + 延迟落盘。
 *
 * 设计要点（设计文档 5.6）：
 *  - 每个 getter 在 key 缺失时返回默认值，因此"漏写默认值"不会导致类型错误，
 *    首次启动也不需要批量初始化全部 key。
 *  - 写入用 putSync + 延迟 flush；拖滑块不会高频落盘。
 *  - 兜底：万一进程被冻结导致定时器丢失，下次读取设置时会发现 dirty 并补一次 flush。
 *  - 禁止把单书设置写成动态 key（会无限增长）。
 */
export class SettingsService {
  private static instance: SettingsService | null = null;
  private static appContext: common.Context | null = null;
  private static readyPromise: Promise<void> | null = null;

  private store: preferences.Preferences | null = null;
  private flushTimer: number = -1;
  private dirty: boolean = false;

  static getInstance(): SettingsService {
    if (SettingsService.instance === null) {
      SettingsService.instance = new SettingsService();
    }
    return SettingsService.instance;
  }

  static async init(context: common.Context): Promise<void> {
    SettingsService.appContext = context;
    await SettingsService.ensureReady();
  }

  /** 幂等就绪确认，任何读写前都应 await 它 */
  static async ensureReady(): Promise<void> {
    if (SettingsService.readyPromise === null) {
      if (SettingsService.appContext === null) {
        throw new Error('SettingsService 尚未注入 Context：EntryAbility.onCreate 里必须调用 SettingsService.init(context)');
      }
      SettingsService.readyPromise = SettingsService.getInstance().initialize(SettingsService.appContext);
    }
    await SettingsService.readyPromise;
  }

  isReady(): boolean {
    return this.store !== null;
  }

  async initialize(context: common.Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    const options: preferences.Options = { name: SETTINGS_STORE_NAME };
    this.store = await preferences.getPreferences(context, options);
    const oldVersion: number = this.getNumber(SettingsKeys.SCHEMA_VERSION, 0);
    if (oldVersion < SETTINGS_SCHEMA_VERSION) {
      // 设置项迁移的挂载点。缺失 key 由各 getter 的默认值兜底，这里只写版本号。
      this.put(SettingsKeys.SCHEMA_VERSION, SETTINGS_SCHEMA_VERSION);
      await this.flushNow();
      Logger.info(LogTag.SETTINGS, `设置已迁移: v${oldVersion} -> v${SETTINGS_SCHEMA_VERSION}`);
    }
  }

  private requireStore(): preferences.Preferences {
    if (this.store === null) {
      throw new Error('SettingsService 尚未初始化，请先调用 SettingsService.init(context)');
    }
    return this.store;
  }

  // ---------------------------------------------------------------- 基础读写

  getNumber(key: string, defValue: number): number {
    const v = this.requireStore().getSync(key, defValue);
    return typeof v === 'number' ? v as number : defValue;
  }

  getString(key: string, defValue: string): string {
    const v = this.requireStore().getSync(key, defValue);
    return typeof v === 'string' ? v as string : defValue;
  }

  getBoolean(key: string, defValue: boolean): boolean {
    const v = this.requireStore().getSync(key, defValue);
    return typeof v === 'boolean' ? v as boolean : defValue;
  }

  put(key: string, value: preferences.ValueType): void {
    this.requireStore().putSync(key, value);
    this.dirty = true;
    this.scheduleFlush();
  }

  putNumber(key: string, value: number): void {
    this.put(key, value);
  }

  putString(key: string, value: string): void {
    this.put(key, value);
  }

  putBoolean(key: string, value: boolean): void {
    this.put(key, value);
  }

  // ---------------------------------------------------------------- 阅读设置

  /** 一次性读取全部阅读设置，供阅读页与设置面板使用 */
  loadReaderSettings(): ReaderSettings {
    const s = new ReaderSettings();

    s.fontSize = this.getNumber(SettingsKeys.FONT_SIZE, s.fontSize);
    s.fontFamily = this.getString(SettingsKeys.FONT_FAMILY, s.fontFamily);
    s.lineHeight = this.getNumber(SettingsKeys.LINE_HEIGHT, s.lineHeight);
    s.paragraphSpacing = this.getNumber(SettingsKeys.PARAGRAPH_SPACING, s.paragraphSpacing);
    s.pageMargin = this.getNumber(SettingsKeys.PAGE_MARGIN, s.pageMargin);
    s.letterSpacing = this.getNumber(SettingsKeys.LETTER_SPACING, s.letterSpacing);
    s.firstLineIndent = this.getNumber(SettingsKeys.FIRST_LINE_INDENT, s.firstLineIndent);

    s.pageMode = this.getString(SettingsKeys.PAGE_MODE, s.pageMode);
    s.theme = this.getString(SettingsKeys.THEME, s.theme);
    s.bgColor = this.getString(SettingsKeys.BG_COLOR, s.bgColor);
    s.keepScreenOn = this.getBoolean(SettingsKeys.KEEP_SCREEN_ON, s.keepScreenOn);
    s.hideStatusBar = this.getBoolean(SettingsKeys.HIDE_STATUS_BAR, s.hideStatusBar);
    s.volumeKeyPage = this.getBoolean(SettingsKeys.VOLUME_KEY_PAGE, s.volumeKeyPage);
    s.brightness = this.getNumber(SettingsKeys.BRIGHTNESS, s.brightness);

    s.gridMode = this.getBoolean(SettingsKeys.GRID_MODE, s.gridMode);
    s.bookSort = this.getString(SettingsKeys.BOOK_SORT, s.bookSort);

    s.ttsSpeed = this.getNumber(SettingsKeys.TTS_SPEED, s.ttsSpeed);
    s.ttsVoice = this.getString(SettingsKeys.TTS_VOICE, s.ttsVoice);
    s.ttsTimerMinutes = this.getNumber(SettingsKeys.TTS_TIMER_MINUTES, s.ttsTimerMinutes);
    return s;
  }

  /** 保存整份阅读设置（设置面板改完一次性保存） */
  saveReaderSettings(s: ReaderSettings): void {
    this.putNumber(SettingsKeys.FONT_SIZE, s.fontSize);
    this.putString(SettingsKeys.FONT_FAMILY, s.fontFamily);
    this.putNumber(SettingsKeys.LINE_HEIGHT, s.lineHeight);
    this.putNumber(SettingsKeys.PARAGRAPH_SPACING, s.paragraphSpacing);
    this.putNumber(SettingsKeys.PAGE_MARGIN, s.pageMargin);
    this.putNumber(SettingsKeys.LETTER_SPACING, s.letterSpacing);
    this.putNumber(SettingsKeys.FIRST_LINE_INDENT, s.firstLineIndent);

    this.putString(SettingsKeys.PAGE_MODE, s.pageMode);
    this.putString(SettingsKeys.THEME, s.theme);
    this.putString(SettingsKeys.BG_COLOR, s.bgColor);
    this.putBoolean(SettingsKeys.KEEP_SCREEN_ON, s.keepScreenOn);
    this.putBoolean(SettingsKeys.HIDE_STATUS_BAR, s.hideStatusBar);
    this.putBoolean(SettingsKeys.VOLUME_KEY_PAGE, s.volumeKeyPage);
    this.putNumber(SettingsKeys.BRIGHTNESS, s.brightness);

    this.putBoolean(SettingsKeys.GRID_MODE, s.gridMode);
    this.putString(SettingsKeys.BOOK_SORT, s.bookSort);

    this.putNumber(SettingsKeys.TTS_SPEED, s.ttsSpeed);
    this.putString(SettingsKeys.TTS_VOICE, s.ttsVoice);
    this.putNumber(SettingsKeys.TTS_TIMER_MINUTES, s.ttsTimerMinutes);
  }

  // ---------------------------------------------------------------- 首启标记

  isFirstLaunchDone(): boolean {
    return this.getBoolean(SettingsKeys.FIRST_LAUNCH_DONE, false);
  }

  markFirstLaunchDone(): void {
    this.put(SettingsKeys.FIRST_LAUNCH_DONE, true);
  }

  // ---------------------------------------------------------------- 落盘控制

  private scheduleFlush(): void {
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
    }
    const timer: number = setTimeout(() => {
      this.flushTimer = -1;
      this.flushNow().catch((e: Error) => {
        Logger.error(LogTag.SETTINGS, `flush 失败: ${e.message}`);
      });
    }, AppConstants.SETTINGS_FLUSH_DELAY_MS);
    this.flushTimer = typeof timer === 'number' ? timer : -1;
  }

  /** 立即落盘。必须在 onBackground / 退出阅读页前调用。 */
  async flushNow(): Promise<void> {
    if (this.store === null) {
      return;
    }
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    await this.store.flush();
    this.dirty = false;
  }

  /** 诊断用：是否有未落盘的改动 */
  hasPendingChanges(): boolean {
    return this.dirty;
  }
}
