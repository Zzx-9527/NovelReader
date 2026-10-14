import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { SETTINGS_STORE_NAME, SettingsKeys } from '../constants/SettingsKeys';
import { AppStateKey } from '../../model/AppState';
import { LogTag } from '../constants/AppConstants';
import { Logger } from '../utils/Logger';

/**
 * **应用级**主题模式 —— 整个 app 的深浅色。
 *
 * ⚠️ 这与 `ReaderTheme` 是**两件完全不同的事**，不要混为一谈：
 *  - `AppThemeMode`（本文件）：控制**整个应用**的配色，靠系统的
 *    `ApplicationContext.setColorMode()` 实现，颜色来自
 *    `resources/base|dark/element/color.json` 两套同名令牌。
 *    影响书架、我的、以及所有用 `AppColor` 的界面。
 *  - `ReaderTheme`（`AppTheme.ets`）：只控制**阅读页正文背景**的四套方案
 *    （浅色/羊皮纸/护眼/夜间），由用户在"设置"面板里选，
 *    颜色是 hex 字符串、**不跟随系统深浅模式**（否则用户选的护眼绿
 *    会在系统切深色时突然变黑）。
 *
 * 所以"设置"里的主题和菜单底栏的"夜间"是两个入口，**互不冲突、各管各的**。
 */
export class AppThemeMode {
  /** 跟随系统（首次安装的默认值） */
  static readonly FOLLOW_SYSTEM: number = 0;
  static readonly LIGHT: number = 1;
  static readonly DARK: number = 2;
}

/**
 * 主题应用器：把应用级主题模式翻译成平台枚举并施加，同时把结果发布到 `AppStorage`。
 *
 * ⚠️ **枚举转换只允许在这里做一处**（设计文档 5.7.5 第 3 条）。
 * 两套枚举的数值顺序**完全不一样**：
 * ```
 * 本项目 AppThemeMode:      平台 ConfigurationConstant.ColorMode:
 *   FOLLOW_SYSTEM = 0         COLOR_MODE_NOT_SET = -1
 *   LIGHT         = 1         COLOR_MODE_DARK    =  0
 *   DARK          = 2         COLOR_MODE_LIGHT   =  1
 * ```
 * 图省事直接把自己的值传给平台，**浅色/深色会正好反掉，而且不报错**。
 *
 * 本类保持**纯逻辑 + 不碰数据库/Preferences 写入**：
 * 落盘由 `ReaderViewModel` 负责（它才持有 `SettingsService`），
 * 这样 `common/` 不必反向依赖 `data/`（分层约定）。
 */
export class ThemeApplier {
  /** 由 `EntryAbility.onCreate` 注入；未注入时 `applyMode` 安全失败 */
  private static appContext: common.ApplicationContext | null = null;
  /**
   * 启动瞬间系统的深浅状态，仅用于 `FOLLOW_SYSTEM` 时判断"现在算不算夜间"。
   *
   * ⚠️ 它在运行期不会更新：用户在系统设置里切深浅、而应用停在
   * `FOLLOW_SYSTEM` 时，这里的高亮态可能滞后。可接受 ——
   * 用户一旦用过一次"夜间"按钮，模式就变成明确的 LIGHT/DARK，不再走这条分支。
   */
  private static systemDark: boolean = false;

  /** 注入应用上下文（`EntryAbility.onCreate` 调用一次） */
  static init(context: common.ApplicationContext, systemDark: boolean): void {
    ThemeApplier.appContext = context;
    ThemeApplier.systemDark = systemDark;
  }

  /**
   * 应用枚举 → 平台枚举。**唯一的转换点**，别处不要再写第二份。
   */
  static toPlatformColorMode(mode: number): ConfigurationConstant.ColorMode {
    if (mode === AppThemeMode.LIGHT) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    if (mode === AppThemeMode.DARK) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }

  /**
   * **同步**读取持久化的主题模式。
   *
   * ⚠️ 必须是同步的：本方法在 `EntryAbility.onCreate` 里、首帧之前调用。
   * 走异步（`getPreferences`）的话，系统会先按默认主题画一帧 ——
   * 深色模式下就是"黑底应用先闪一下白屏"（设计文档 5.7.5 第 2 条）。
   * `getPreferencesSync` + `getSync` 是同步 API，正是为这个场景存在的。
   *
   * ⚠️ 这里只**读**、不写：写入一律走 `SettingsService`，
   * 避免出现两个 Preferences 实例各自 flush 的混乱。
   */
  static readPersistedModeSync(context: common.Context): number {
    try {
      const options: preferences.Options = { name: SETTINGS_STORE_NAME };
      const store: preferences.Preferences = preferences.getPreferencesSync(context, options);
      const raw: preferences.ValueType = store.getSync(SettingsKeys.APP_THEME_MODE, AppThemeMode.FOLLOW_SYSTEM);
      return typeof raw === 'number' ? raw as number : AppThemeMode.FOLLOW_SYSTEM;
    } catch (e) {
      // 读不到就按"跟随系统"处理：这是最不打扰用户的降级
      Logger.warn(LogTag.SETTINGS, `读取应用主题失败，按跟随系统处理: ${Logger.errText(e as Object)}`);
      return AppThemeMode.FOLLOW_SYSTEM;
    }
  }

  /**
   * 施加主题模式，并把"当前是否夜间"发布到 `AppStorage`。
   *
   * @returns 是否成功。失败时**调用方不应落盘** ——
   *   否则设置存下来了却没生效，用户看到的是"点了没反应，重启才变"
   *   （设计文档 5.7.5 第 4 条：先应用、再落盘）。
   */
  static applyMode(mode: number): boolean {
    /**
     * ⚠️ 先取到**局部变量**再判空，不直接连着写 `ThemeApplier.appContext.xxx`。
     *
     * 静态字段在 ArkTS 里**不保证被收窄**（`if (X.y !== null)` 之后
     * `X.y.foo()` 仍可能被判定为"对象可能为 null"）——
     * 取成局部 `const` 后类型收窄是确定的，不依赖编译器行为。
     */
    const appContext: common.ApplicationContext | null = ThemeApplier.appContext;
    if (appContext === null) {
      Logger.warn(LogTag.SETTINGS, 'ThemeApplier 未初始化，主题未应用');
      return false;
    }
    try {
      appContext.setColorMode(ThemeApplier.toPlatformColorMode(mode));
      ThemeApplier.publishDarkState(mode);
      return true;
    } catch (e) {
      Logger.error(LogTag.SETTINGS, `应用主题失败: ${Logger.errText(e as Object)}`);
      return false;
    }
  }

  /**
   * 发布"当前是否夜间"到 `AppStorage`，供页面用 `@StorageProp` 订阅高亮态。
   *
   * 页面拿不到"系统现在是不是深色"（那要 `Context.config`），
   * 所以在这里算一次、全局共享 —— 与 `safeAreaTop` 同一套范式。
   */
  private static publishDarkState(mode: number): void {
    const dark: boolean = mode === AppThemeMode.DARK
      || (mode === AppThemeMode.FOLLOW_SYSTEM && ThemeApplier.systemDark);
    AppStorage.setOrCreate<boolean>(AppStateKey.APP_DARK_MODE, dark);
  }

  /** 当前是否夜间（读 `AppStorage`，与页面订阅的是同一个值） */
  static isDark(): boolean {
    return AppStorage.get<boolean>(AppStateKey.APP_DARK_MODE) ?? false;
  }

  /** 夜间 ↔ 浅色的下一个模式（不落盘，只算） */
  static nextToggleMode(): number {
    return ThemeApplier.isDark() ? AppThemeMode.LIGHT : AppThemeMode.DARK;
  }
}
