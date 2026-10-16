import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { KeyCode, inputConsumer, KeyEvent } from '@kit.InputKit';
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

  /**
   * 设置阅读时屏幕常亮。
   *
   * ⚠️ 离开阅读页必须传 `false` 恢复：常亮是**窗口属性**，
   * 不恢复的话用户退到书架、甚至别的应用（若窗口共享）都保持常亮，
   * 费电且违背"只在阅读时生效"的语义。
   * 调用点在 `ReaderPage.aboutToDisappear`，与 `applyBrightness(-1)` 恢复亮度同一时机。
   */
  static async applyKeepScreenOn(context: common.Context, keepOn: boolean): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(context);
      await win.setWindowKeepScreenOn(keepOn);
    } catch (e) {
      Logger.warn(LogTag.READ, `设置常亮失败（可能被系统策略拒绝）: ${Logger.errText(e as Object)}`);
    }
  }

  /**
   * 显示/隐藏系统状态栏。
   *
   * ## 语义
   *
   * 阅读页的"隐藏状态栏"是**正文态专属**的沉浸增强：
   *  - `hide=true`（正文阅读中）→ 状态栏隐藏，正文多出一行空间；
   *  - `hide=false`（菜单/设置面板弹出，或离开阅读页）→ 恢复显示。
   *
   * ⚠️ 恢复是**自动的**，不让用户管：菜单里的"返回"按钮在状态栏下面
   * 既看不清也点不到 —— 隐藏必须随浮层让位，这是页面同步逻辑的事
   * （见 `ReaderPage.syncWindowChrome`），本方法只负责调 API。
   *
   * ## 用 SystemBarEnable 而不是 setWindowSystemBarProperties
   *
   * 透明化背景色只是"看不见字但那块还在"，触摸与高度占位都留着；
   * `setWindowSystemBarEnable([])` 才是真正把系统条从屏幕上撤掉。
   * 恢复时显式列出 `'status'`（导航条由全屏布局自己处理，始终给 `'navigation'`）。
   *
   * ⚠️ 与沉浸式全屏的关系：`setWindowLayoutFullScreen(true)`（Ability 启动时
   * 已设）是前提；本方法只在"系统条要不要显示"这一层切换。
   * 页面的安全区 padding 不用跟着变 —— 状态栏隐藏后顶部安全区高度归零，
   * 内容自然上移，`@StorageProp('safeAreaTop')` 的订阅会自动重排。
   */
  static async applySystemBarsVisible(context: common.Context, visible: boolean): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(context);
      if (visible) {
        await win.setWindowSystemBarEnable(['status', 'navigation']);
      } else {
        await win.setWindowSystemBarEnable(['navigation']);
      }
    } catch (e) {
      // 部分机型/系统策略不允许应用隐藏系统条 —— 记日志、当没发生
      Logger.warn(LogTag.READ, `切换状态栏显隐失败（可能被系统策略拒绝）: ${Logger.errText(e as Object)}`);
    }
  }

  /**
   * 注册音量键翻页监听，解析为注销函数（注册失败时解析为 null）。
   *
   * ## 为什么在窗口上拦截，而不是页面 `onKeyEvent`
   *
   * ArkUI 的 `onKeyEvent` 只在**焦点组件**上触发，而阅读页的焦点归属
   * 会随"长按选中 / 弹窗 / 面板"漂移，监听会随机失效；
   * `inputConsumer.on('keyPressed')` 是应用级的，不受焦点影响 —— 翻页这种
   * "随时都要响应"的操作必须挂在应用级监听上。
   *
   * ## inputConsumer 代替 window.on('keyEvent')
   *
   * SDK 22 起 `window.on('keyEvent')` 已移除，改用 `inputConsumer.on('keyPressed')`。
   * 优势：
   *  - **能拦截系统音量调节**：订阅后系统不再弹出音量面板（旧方案做不到）；
   *  - **不依赖 Window 对象**：省去 `getLastWindow` 异步取窗口的步骤。
   *
   * 方法签名保持 async 以便平滑替换调用方代码。
   *
   * 返回值：
   *  - **null** = 注册失败，调用方按"未启用"处理（静默）；
   *  - **注销函数** = 移除监听。**页面销毁时必须调用**，
   *    否则重建后可能重复注册导致翻页响应多次。
   *
   * ⚠️ 回调里必须 try/catch：翻页方法内部若抛错，异常会沿系统回调
   * 传播成未处理拒绝，表现为"按一次键之后再也不响应"。
   *
   * @param context 页面 Context（保留兼容，不再使用）
   * @param onPrev 按"音量减"（向下翻，与阅读方向一致）
   * @param onNext 按"音量加"（向上翻）
   * @returns Promise；resolve 出注销函数（或 null = 未注册成功）
   */
  static async registerVolumeKeyPaging(context: common.Context,
    onPrev: () => void, onNext: () => void): Promise<(() => void) | null> {
    // 使用 inputConsumer 订阅音量键按下事件：
    // - inputConsumer 拦截优先级高，能阻止系统音量调节面板弹出
    // - 通过 action: 1（按下）过滤，松开（UP）不触发，避免一次按键翻两页
    // - isRepeat: true 允许长按连续翻页
    const nextHandler = (): void => {
      try {
        onNext();
      } catch (e) {
        Logger.error(LogTag.READ, `音量+翻页回调异常: ${Logger.errText(e as Object)}`);
      }
    };
    const prevHandler = (): void => {
      try {
        onPrev();
      } catch (e) {
        Logger.error(LogTag.READ, `音量-翻页回调异常: ${Logger.errText(e as Object)}`);
      }
    };

    let registeredUp = false;
    let registeredDown = false;

    try {
      inputConsumer.on('keyPressed', {
        key: KeyCode.KEYCODE_VOLUME_UP,
        action: 1,
        isRepeat: true,
      }, nextHandler);
      registeredUp = true;
    } catch (e) {
      Logger.warn(LogTag.READ, `音量+键订阅失败: ${Logger.errText(e as Object)}`);
    }

    try {
      inputConsumer.on('keyPressed', {
        key: KeyCode.KEYCODE_VOLUME_DOWN,
        action: 1,
        isRepeat: true,
      }, prevHandler);
      registeredDown = true;
    } catch (e) {
      Logger.warn(LogTag.READ, `音量-键订阅失败: ${Logger.errText(e as Object)}`);
    }

    if (!registeredUp && !registeredDown) {
      return null;
    }

    return (): void => {
      try {
        if (registeredUp) {
          inputConsumer.off('keyPressed', nextHandler);
        }
        if (registeredDown) {
          inputConsumer.off('keyPressed', prevHandler);
        }
      } catch (e) {
        Logger.warn(LogTag.READ, `音量键翻页注销失败: ${Logger.errText(e as Object)}`);
      }
    };
  }
}
