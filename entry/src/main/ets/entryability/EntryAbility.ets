import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { StorageBootstrap } from '../common/StorageBootstrap';
import { SettingsService } from '../data/service/SettingsService';
import { Logger } from '../common/utils/Logger';
import { LogTag } from '../common/constants/AppConstants';
import { RouteName } from '../model/RouteParam';
import { AppStateKey } from '../model/AppState';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    // 存储底座：注入 Context 并开始初始化（不阻塞窗口创建）。
    // 页面在数据访问前会 await 各自的 ensureReady()，所以不存在"UI 抢跑"问题。
    StorageBootstrap.bootstrap(this.context);

    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    /**
     * 开启**沉浸式全屏布局**：整个 app 的内容延伸到状态栏与手势条区域。
     *
     * ⚠️ 这一步是各页面 `expandSafeArea(...)` 生效的**前提**（本项目实测踩过）。
     * 默认窗口是"非全屏布局"，内容区已被系统扣掉安全区；
     * 此时页面里写 `expandSafeArea` 只能扩展绘制、改不了布局位置 ——
     * 表现就是"阅读页底栏永远悬在安全区上方，怎么调都贴不到底"。
     *
     * 开启后**每个页面自己负责**为状态栏/手势条留出余量：
     * 安全区高度由这里测一次、放进 `AppStorage` 全局共享
     * （页面拿不到 `Window`，测不了），页面用 `@StorageProp` 订阅。
     *
     * 失败不致命：退化成普通布局，只是贴不到屏幕边缘。
     */
    windowStage.getMainWindow()
      .then((mainWindow: window.Window) => {
        return mainWindow.setWindowLayoutFullScreen(true).then(() => {
          EntryAbility.publishSafeArea(mainWindow);
        });
      })
      .then(() => {
        hilog.info(DOMAIN, TAG, '%{public}s', 'Succeeded in enabling full-screen layout.');
      })
      .catch((err: Object) => {
        hilog.error(DOMAIN, TAG, 'Failed to enable full-screen layout. Cause: %{public}s',
          JSON.stringify(err));
      });

    // 首个页面是启动页：它负责预热存储底座（见 SplashPage 说明），
    // 预热完成后用 replaceUrl 跳到 pages/Index。
    // 路径走 RouteName 常量，避免与 main_pages.json 登记的名字两处各写一遍。
    windowStage.loadContent(RouteName.SPLASH_PAGE, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  /**
   * 测量顶部/底部安全区高度，换算成 **vp** 后放进 `AppStorage` 供页面订阅。
   *
   * 为什么必须测：开启沉浸式全屏后，窗口内容会盖住状态栏与手势条，
   * 各页面得**自己**让出这段高度。而 `Window` 只有 Ability 拿得到，
   * 页面拿不到 —— 所以在这里测一次、全局共享。
   *
   * ⚠️ 两点容易错：
   *  1. `AvoidArea` 的 `Rect` 单位是 **px**，而布局用的是 **vp** ——
   *     必须用 `window.getUIContext().px2vp()` 换算，否则顶部会让出约 3 倍高度。
   *  2. 底部手势条要用 `TYPE_NAVIGATION_INDICATOR`（= 4）；
   *     用 `TYPE_SYSTEM` 在部分设备上取到的是整条导航栏，高度偏大。
   */
  private static publishSafeArea(mainWindow: window.Window): void {
    try {
      const uiContext = mainWindow.getUIContext();
      const topPx: number = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
      const bottomPx: number =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      const topVp: number = uiContext.px2vp(topPx);
      const bottomVp: number = uiContext.px2vp(bottomPx);
      AppStorage.setOrCreate<number>(AppStateKey.SAFE_AREA_TOP, topVp);
      AppStorage.setOrCreate<number>(AppStateKey.SAFE_AREA_BOTTOM, bottomVp);
      hilog.info(DOMAIN, TAG, 'safe area top=%{public}s vp, bottom=%{public}s vp',
        topVp.toFixed(1), bottomVp.toFixed(1));
    } catch (err) {
      // 取不到就保持 0：页面退化成"不让位"，顶多贴边不好看，不影响功能
      hilog.error(DOMAIN, TAG, 'Failed to read avoid area. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // 阅读进度由阅读页自己结算；这里兜底把设置落盘
    SettingsService.getInstance().flushNow().catch((e: Object) => {
      Logger.error(LogTag.SETTINGS, `设置落盘失败: ${Logger.errText(e)}`);
    });
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
