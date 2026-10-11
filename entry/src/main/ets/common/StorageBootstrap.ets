import { common } from '@kit.AbilityKit';
import { AppContext } from './AppContext';
import { PathUtil } from './utils/PathUtil';
import { RdbHelper } from '../data/database/RdbHelper';
import { SettingsService } from '../data/service/SettingsService';
import { Logger } from './utils/Logger';
import { LogTag } from './constants/AppConstants';

/**
 * 存储底座初始化。
 *
 * 解决的问题：`PathUtil` / `RdbHelper` / `SettingsService` 都要求先 init，
 * 而页面/ViewModel 里既不该写重复的初始化代码，顺序错了还会在首次使用时抛错。
 *
 * 分两层保证：
 *  1. 本类在 `EntryAbility.onCreate` 调一次，串起三者的初始化；
 *  2. `RdbHelper.ensureReady()` / `SettingsService.ensureReady()` 各自幂等，
 *     所以即使 UI 抢在初始化完成前发起查询，也只是 await 同一个 Promise，不会抛错。
 *
 * 注意依赖方向：本类依赖各服务，各服务**不**依赖本类，避免循环引用。
 */
export class StorageBootstrap {
  private static initPromise: Promise<void> | null = null;

  /** 启动时注入 Context 并开始初始化（不阻塞调用方） */
  static bootstrap(context: common.Context): void {
    AppContext.init(context);
    // 故意不 await：初始化是 IO，不应阻塞窗口创建
    StorageBootstrap.ensureReady().catch((e: Object) => {
      Logger.error(LogTag.DB, `存储初始化失败: ${Logger.errText(e)}`);
    });
  }

  /** 幂等就绪确认 */
  static async ensureReady(): Promise<void> {
    if (StorageBootstrap.initPromise === null) {
      StorageBootstrap.initPromise = StorageBootstrap.doInit();
    }
    await StorageBootstrap.initPromise;
  }

  private static async doInit(): Promise<void> {
    const context: common.Context = AppContext.get();
    PathUtil.init(context);
    await RdbHelper.init(context);
    await SettingsService.init(context);
    Logger.info(LogTag.DB, '存储底座初始化完成');
  }

  /** 诊断用 */
  static isReady(): boolean {
    return StorageBootstrap.initPromise !== null
      && PathUtil.isReady()
      && RdbHelper.getInstance().isReady();
  }
}
