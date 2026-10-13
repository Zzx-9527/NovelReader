import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { RouteName } from '../model/RouteParam';
import { StorageBootstrap } from '../common/StorageBootstrap';
import { Logger } from '../common/utils/Logger';
import { LogTag } from '../common/constants/AppConstants';
import { ErrorView } from '../views/common/ErrorView';

/**
 * 应用名与 slogan。
 * ⚠️ 与"我的"页脚（`ProfilePage`）必须一致 —— 品牌文案只有这一份口径，
 * 改这里请把那边一起改，否则同一个 App 会出现两种自我描述。
 */
const APP_NAME: string = '静读';
const SLOGAN: string = '本地导入 · 离线阅读 · 无广告 · 不上传任何内容';

/** 品牌区淡入时长 */
const REVEAL_DURATION_MS: number = 420;
/** 路由失败后的重试间隔 */
const NAV_RETRY_DELAY_MS: number = 300;
/** 路由失败的最大自动重试次数，超过则显示错误态等用户手动重试 */
const MAX_NAV_RETRIES: number = 2;

/**
 * 启动页。
 *
 * **它存在两件事要做，缺一不可**：
 *
 * 1. **盖住系统启动窗口之后的空档**。
 *    冷启动其实是三层：`系统启动窗口 → 启动页 → 书架`。
 *    系统那层由 `module.json5` 的 `startWindowIcon/startWindowBackground` 画，
 *    它删不掉；如果删掉启动页，用户看到的就是"图标 → 书架白屏很久"。
 *    所以本页背景**必须**用 `$r('app.color.splash_bg')` —— 与
 *    `startWindowBackground` 同一个令牌，换层时才不会闪一下颜色（见 §5.7.2）。
 *
 * 2. **把存储底座预热完再放人进去**。
 *    `StorageBootstrap` 在 `EntryAbility.onCreate` 里只是**发起**初始化（故意不 await，
 *    否则阻塞窗口创建）。本页 `await` 同一个幂等 Promise，等到位再跳书架，
 *    这样书架页首次查询不会撞上"数据库还没建好"。
 *
 * 时间控制是两头夹：**最少**停留 `SPLASH_MIN_MS`（预热太快时也要让品牌露个脸，
 * 否则就是白屏一闪），**最多**等 `SPLASH_TIMEOUT_MS`（预热挂住也必须跳走，
 * 绝不能把用户扣在启动页）。
 *
 * 跳转用 `replaceUrl` 而不是 `pushUrl`：启动页不该留在返回栈里，
 * 否则用户在书架上按返回会退回启动页。
 */
@Entry
@Component
struct SplashPage {
  /** 品牌区淡入用；初值 false → 由 onAppear 触发动画 */
  @State revealed: boolean = false;
  /** 跳转彻底失败（含重试用尽）时显示错误态，而不是一个永远转的圈 */
  @State failed: boolean = false;

  /**
   * 安全区高度（vp），由 `EntryAbility` 测好后放进 `AppStorage`。
   * 整个 app 沉浸式全屏，本页也要让出上下两条，
   * 否则品牌区会与状态栏/手势条挤在一起。
   */
  @StorageProp('safeAreaTop') safeAreaTop: number = 0;
  @StorageProp('safeAreaBottom') safeAreaBottom: number = 0;

  /** 已发起跳转：预热回调与超时定时器可能同时到达，用它做去重 */
  private leaving: boolean = false;
  /** 页面已销毁：此后落地的定时器一律空转，不再碰路由 */
  private gone: boolean = false;
  private navRetries: number = 0;

  aboutToAppear(): void {
    this.warmUp();
  }

  aboutToDisappear(): void {
    // 只置标志、不 clearTimeout：本页最多挂 2 个 ≤3s 的定时器，
    // 它们在 goHome() 里被 leaving/gone 挡掉，记账成本比 clearTimeout 低。
    this.gone = true;
  }

  /**
   * 预热存储底座，并在"最短停留"与"硬超时"之间跳转到书架。
   *
   * 用 setTimeout + 标志位而不是 `Promise.race`：race 有个坑 ——
   * 超时先到后，`ensureReady()` 若再 reject 就成了**无人处理的 Promise 拒绝**，
   * 会污染日志。这里所有分支（成功 / 失败 / 超时）都收敛到同一个 `leave()`。
   */
  private warmUp(): void {
    const startAt: number = Date.now();
    let settled: boolean = false;

    const leave: () => void = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      // 最短停留：预热快于 SPLASH_MIN_MS 时，补足差额再走
      const remain: number = AppTheme.SPLASH_MIN_MS - (Date.now() - startAt);
      setTimeout(() => {
        this.goHome();
      }, Math.max(0, remain));
    };

    // 硬超时：先记一条日志再走，方便定位"到底是不是预热慢"
    setTimeout(() => {
      if (!settled) {
        Logger.warn(LogTag.DB,
          `存储预热超过 ${AppTheme.SPLASH_TIMEOUT_MS}ms，先进入书架（书架页会继续 await）`);
      }
      leave();
    }, AppTheme.SPLASH_TIMEOUT_MS);

    StorageBootstrap.ensureReady()
      .then(() => {
        leave();
      })
      .catch((e: Object) => {
        // 预热失败也照常进书架：书架页自带错误态，比卡在启动页更有用
        Logger.error(LogTag.DB, `存储预热失败，仍进入书架: ${Logger.errText(e)}`);
        leave();
      });
  }

  /** 进入书架；失败自动重试有限次，用尽后转为错误态 */
  private goHome(): void {
    if (this.leaving || this.gone) {
      return;
    }
    this.leaving = true;
    this.failed = false;
    // ⚠️ 用 UIContext 上的 Router：@ohos.router 的全局函数已废弃（见 §5.6 第 19 条）
    this.getUIContext().getRouter()
      .replaceUrl({ url: RouteName.INDEX_PAGE })
      .catch((e: Object) => {
        this.leaving = false;
        Logger.error(LogTag.DB, `进入书架失败: ${Logger.errText(e)}`);
        if (this.navRetries < MAX_NAV_RETRIES) {
          this.navRetries++;
          setTimeout(() => {
            this.goHome();
          }, NAV_RETRY_DELAY_MS);
        } else {
          this.failed = true;
        }
      });
  }

  build() {
    Column() {
      if (this.failed) {
        ErrorView({
          message: '进入书架失败',
          hint: '存储初始化未完成或页面路由异常，可点击重试',
          actionText: '重试',
          onRetry: () => {
            this.navRetries = 0;
            this.goHome();
          }
        })
      } else {
        // 上半段留白 + 品牌区 + 下半段留白：品牌落在视觉中心附近，
        // 与系统启动窗口居中的图标位置尽量对齐，换层时"图标不怎么动"
        Blank()

        Column({ space: AppTheme.GAP_M }) {
          // 与 startWindowIcon 同一张图：系统窗口 → 启动页这一步图形不变
          Image($r('app.media.startIcon'))
            .width(96)
            .height(96)
            .objectFit(ImageFit.Contain)

          Text(APP_NAME)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)

          Text(SLOGAN)
            .fontSize(AppTheme.FONT_SLOGAN)
            .fontColor(AppColor.textSecondary)
            .textAlign(TextAlign.Center)
        }
        .alignItems(HorizontalAlign.Center)
        .opacity(this.revealed ? 1 : 0)
        .onAppear(() => {
          // 放 onAppear 而不是 aboutToAppear：后者阶段组件还没上树，
          // 状态在首次 build 前就被改成 1，动画等于没做。
          // 万一时序异常，这里的赋值也是**同步**生效的，不会把内容永久留在透明态。
          this.getUIContext().animateTo({
            duration: REVEAL_DURATION_MS,
            curve: Curve.EaseOut
          }, () => {
            this.revealed = true;
          });
        })

        Blank()

        LoadingProgress()
          .width(28)
          .height(28)
          .color(AppColor.brand)
          .margin({ bottom: 56 })
      }
    }
    .width('100%')
    .height('100%')
    // 让出上下安全区：品牌区与加载圈都落在状态栏/手势条之间，
    // 背景色仍铺满全屏（沉浸式），不会露出系统色边
    .padding({
      left: AppTheme.PAGE_PADDING,
      right: AppTheme.PAGE_PADDING,
      top: this.safeAreaTop + AppTheme.PAGE_PADDING,
      bottom: this.safeAreaBottom
    })
    // ⚠️ 必须是 splash_bg：与 module.json5 的 startWindowBackground 同一令牌
    .backgroundColor(AppColor.splashBg)
    /**
     * 让整页**铺满屏幕**（含状态栏与手势条区域）—— 沉浸式的基础。
     *
     * ⚠️ 与上面的 `padding` 分工不同，两者缺一不可：
     *  - `expandSafeArea` 决定**绘制范围** → 背景铺到屏幕最边缘，与
     *    系统启动窗口的 `startWindowBackground` 无缝相接（否则会闪一条色边）；
     *  - `padding` 决定**内容范围** → 品牌区/加载圈不钻到状态栏、手势条下面。
     */
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
