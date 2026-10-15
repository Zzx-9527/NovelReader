import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { StorageBootstrap } from '../common/StorageBootstrap';
import { SettingsService } from '../data/service/SettingsService';
import { Logger } from '../common/utils/Logger';
import { LogTag } from '../common/constants/AppConstants';
import { RouteName } from '../model/RouteParam';
import { AppStateKey } from '../model/AppState';
import { ThemeApplier } from '../common/theme/ThemeApplier';
import { AppFont } from '../common/theme/AppFont';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    /**
     * 应用级主题：**必须在首帧之前同步设好**。
     *
     * ⚠️ 三步顺序不能动：
     *  1. 读一次系统当前深浅色（下面 `isSystemDark`），
     *     因为 `FOLLOW_SYSTEM` 时要靠它判断"现在算不算夜间"；
     *  2. `ThemeApplier.init` 注入 ApplicationContext；
     *  3. **同步**读持久化模式并施加。
     *
     * ⚠️ 第 3 步必须同步：走异步的话系统会先按默认主题画一帧 ——
     * 深色模式下就是"黑底应用先闪一下白屏"（设计文档 5.7.5 第 2 条）。
     *
     * ⚠️ 原实现在这里硬写 `COLOR_MODE_NOT_SET`，等于**每次启动都把主题
     * 重置成跟随系统**，用户选了夜间也会被覆盖掉。现在改为读持久化值。
     */
    /**
     * ⚠️ 显式标注类型，不靠推断：ArkTS 禁止隐式 `any`，
     * 而"从有类型的返回值推断"虽然合法，写出来更能避免日后换 API 时静默退化成 any。
     */
    const appContext: common.ApplicationContext = this.context.getApplicationContext();
    ThemeApplier.init(appContext, this.isSystemDark());
    const savedMode: number = ThemeApplier.readPersistedModeSync(this.context);
    ThemeApplier.applyMode(savedMode);

    // 存储底座：注入 Context 并开始初始化（不阻塞窗口创建）。
    // 页面在数据访问前会 await 各自的 ensureReady()，所以不存在"UI 抢跑"问题。
    StorageBootstrap.bootstrap(this.context);

    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  /**
   * 系统当前是否为深色。
   *
   * ⚠️ 只在 `FOLLOW_SYSTEM` 时用来决定"夜间"按钮的高亮态。
   * 取不到就按浅色处理：这只是个显示态，不值得为它中断启动。
   */
  private isSystemDark(): boolean {
    try {
      const config: Configuration = this.context.config;
      return config !== undefined
        && config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (err) {
      return false;
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    /**
     * 标题字体：探测系统是否自带中文衬线（**仅 2-in-1 设备可能命中**）。
     *
     * ⚠️ 必须在 `loadContent` **之前**同步执行。改成异步会引入一个可见的缺陷：
     * `getMainWindow()` 走的是 **Promise**（下面那条链），而 `loadContent`
     * 是**紧接着同步执行**的 —— 两者之间没有先后保证。
     * 若把探测挂在下面那条 `.then()` 里，启动页的首帧往往**早于**探测完成，
     * 于是「静读」两个字会先按无衬线画一帧、再重绘成衬线：
     * 肉眼看到的就是**字体闪一下**。而启动页恰好是全 app 唯一一屏
     * "整屏只有品牌"的页面，字体切换在那里最显眼。
     * 所以这里用 `getMainWindowSync()` 拿窗口、**同步**探测。
     *
     * ⚠️ 本项目**不引入**衬线字体文件（理由见 `AppFont` 的类注释：
     * 中文衬线动辄 20MB，而标题只用到几十个字，与"轻量"定位不相称）。
     * 所以这次探测是"有则更好、没有就回退无衬线"，**不是**设计的依赖项 ——
     * 手机上它基本不会命中，这是预期内的。
     *
     * ⚠️ `probe` 自己吞掉所有内部异常，这里只需要处理
     * `getMainWindowSync()` 本身可能抛出的异常。字体是装饰，绝不该影响启动。
     */
    try {
      AppFont.probe(windowStage.getMainWindowSync().getUIContext());
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to probe title font. Cause: %{public}s', JSON.stringify(err));
    }

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
      /**
       * ⚠️ 字体注册**不在这里** —— 它已经移到 `onWindowStageCreate` 里、
       * `loadContent` **之前**同步执行（见那边的说明：放这里晚于启动页首帧，
       * 会让品牌 wordmark 闪一下字体）。
       *
       * 本方法只负责"安全区"这一件事。系统衬线的探测（`AppFont.probe`）
       * 也跟着一起移走了：它虽然不急着赶首帧，但与注册是同一类事，
       * 两处分开写只会让"字体到底在哪初始化的"变得难找。
       */
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
