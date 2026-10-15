import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Logger } from '../utils/Logger';
import { LogTag } from '../constants/AppConstants';

/**
 * 阅读页的**窗口级效果**：屏幕亮度、保持常亮。
 *
 * ## 为什么需要单独一层
 *
 * 这三件事都需要 `window.Window`，而**页面拿不到它** ——
 * 与"安全区高度只有 `EntryAbility` 测得到"是同一个约束
 * （见 `AppStateKey.SAFE_AREA_TOP` 的说明）。
 *
 * 但这里**不能**照搬安全区的做法（在 Ability 里测一次、塞进 AppStorage）：
 * 亮度与常亮是**随用户改设置实时变化**的，而 Ability 只在窗口创建时跑一次。
 * 所以改成"页面在需要时自己取窗口"—— 用 `window.getLastWindow(context)`
 * 从页面的 `UIContext` 拿到 Context 再去取。
 *
 * ## 三条纪律
 *
 * 1. **绝不抛异常给调用方**。亮度是可以被系统策略拒绝的（省电模式、
 *    部分机型不允许第三方应用改亮度），常亮同理。这些失败**不该**
 *    让"改设置"这个动作失败 —— 用户改的是设置，不是窗口。
 *    所以每个方法自己吞掉异常，只记一条日志。
 * 2. **每次应用都重新取窗口**，不缓存。窗口在应用生命周期内可能被重建
 *    （分屏切换、折叠屏展开、多实例），缓存下来的 `Window` 会指向失效对象，
 *    而用它调 API 是**静默无效**的（不报错、只是不生效）。
 * 3. **幂等**：重复设同一个值与设一次等价，所以调用方不需要判断"值有没有变"。
 */
export class ReaderWindowEffects {
  /**
   * 设置窗口亮度。
   *
   * ⚠️ 入参语义与 `ReaderSettings.brightness` 对齐：
   *  - **-1 表示"跟随系统"**，此时必须调 `setWindowBrightness(-1)`
   *    把控制权交回系统，而**不是**跳过调用 ——
   *    跳过的话用户从"手动 0.8"切回"跟随系统"，屏幕会一直停在 0.8。
   *  - 0~1 是有效区间，越界由系统夹取。
   *
   * @param context 页面拿到的 Context（`getUIContext().getHostContext()`）
   * @param brightness -1 或 0~1
   */
  static async applyBrightness(context: common.Context, brightness: number): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(context);
      await win.setWindowBrightness(brightness);
    } catch (e) {
      // 系统策略拒绝（省电模式等）属正常情况，不值得打扰用户
      Logger.warn(LogTag.READ, `设置亮度失败（可能被系统策略拒绝）: ${Logger.errText(e as Object)}`);
    }
  }
}
