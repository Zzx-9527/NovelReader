import { BookShelfViewModel } from './BookShelfViewModel';

/**
 * 书架刷新登记表（页面与 ViewModel 之间的一根"电话线"）。
 *
 * 解决的问题：`onPageShow` / `onForeground` 这类"回到页面"的时机
 * 只会派发给 `@Entry` 页面，而书架页是普通 `@Component`，拿不到这些回调。
 * 可"从阅读页返回后进度要同步"又必须踩在一个可靠时机上。
 *
 * 做法：
 *  - 书架页在 `aboutToAppear` 里把自己的 ViewModel 登记进来（`current = vm`），
 *    在 `aboutToDisappear` 里撤销登记（且只在登记的还是自己时才清空，
 *    避免后挂载的页面被先卸载的页面误清）；
 *  - 根页面 `Index` 在 `onPageShow` 与"切回书架 Tab"时调用 `refresh()`，
 *    由这里转发给当前在架的书架 ViewModel。
 *
 * 注意：这里只存引用、不持有生命周期 —— ViewModel 的创建与销毁仍归页面，
 * 注册表不会阻止它被回收，也不会在页面销毁后继续刷新。
 */
export class ShelfRefreshRegistry {
  /**
   * 当前在架的书架 ViewModel；无书架页时为 null。
   * 直接用静态字段而不是 getter/setter：调用方的读写都是显式的，
   * 少一层间接，出问题也更容易定位。
   */
  static current: BookShelfViewModel | null = null;

  /**
   * 刷新书架数据。
   *
   * 没有已登记的书架页时静默返回 —— 例如 App 启动瞬间根页面 `onPageShow`
   * 早于书架页的 `aboutToAppear`，此时无数据可刷，不该报错。
   */
  static refresh(): void {
    const vm: BookShelfViewModel | null = ShelfRefreshRegistry.current;
    if (vm === null) {
      return;
    }
    // reloadData 内部已 try/catch 并把错误写进 state.error，这里无需再兜一层；
    // 显式接住 Promise 只是为了避免"未处理的 Promise 拒绝"告警。
    vm.reloadData().catch(() => {
    });
  }
}
