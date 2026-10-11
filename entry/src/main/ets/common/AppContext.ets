import { common } from '@kit.AbilityKit';

/**
 * 应用级 Context 持有者。
 *
 * 为什么需要它：`PathUtil` / `RdbHelper` / `SettingsService` 都需要 Context 才能初始化，
 * 而 ViewModel 里拿不到 Context（它不该依赖 UI 层）。
 * 由 `EntryAbility.onCreate` 在启动时注入一次，之后全应用通过本类取用。
 *
 * 注意：这里只存 Context，不做任何 IO；真正的初始化在 StorageBootstrap 里。
 */
export class AppContext {
  private static context: common.Context | null = null;

  static init(context: common.Context): void {
    AppContext.context = context;
  }

  static get(): common.Context {
    if (AppContext.context === null) {
      throw new Error('AppContext 尚未初始化：EntryAbility.onCreate 里必须调用 AppContext.init(context)');
    }
    return AppContext.context;
  }

  static isReady(): boolean {
    return AppContext.context !== null;
  }
}
