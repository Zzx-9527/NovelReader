/**
 * 目录页 → 阅读页的"跳章请求"登记表。
 *
 * 解决的问题：目录已从**弹窗**改成**独立页面**（`ReaderCatalogPage`），
 * 用户在那边点了某一章，阅读页得知道"跳到哪一章、章内哪个偏移"。
 *
 * 为什么不用路由回传参数（`router.back(index, params)`）：
 *  - `back(index, params)` 的 `index` 是**页面栈下标**，而栈深取决于
 *    用户是从书架还是从别处进来的（Splash → Index → Reader → Catalog），
 *    写死一个数字非常脆；
 *  - `back({ url, params })` 的文档只承诺"回到该页、不重建"，
 *    **没有**承诺 params 会被目标页的 `getParams()` 取到。
 *
 * 所以沿用本项目已有的 `ShelfRefreshRegistry` 范式：静态登记表 + 页面主动领取。
 * 阅读页在 `onPageShow` 里 `consume()`，拿到就跳、拿不到就什么都不做。
 *
 * 注意：只存一个"待办"，且**取走即清空** ——
 * 否则用户下次切后台再回来（`onPageShow` 会再触发）会莫名其妙又跳一次。
 */
export class ReaderJump {
  /** 目标章序号（0-based） */
  chapterIndex: number = -1;
  /**
   * 章内 UTF-16 偏移；**-1 表示未指定**，阅读页会落到章首。
   *
   * ⚠️ 不能用 -1 直接传给 `switchChapter` —— 在那里 -1 的含义是
   * "定位到**章末**"（上一章回退时用的）。语义必须在这里翻译一次。
   */
  offset: number = -1;
}

export class ReaderJumpRegistry {
  private static pending: ReaderJump | null = null;

  /** 目录页登记一个跳章请求 */
  static request(chapterIndex: number, offset: number): void {
    const jump = new ReaderJump();
    jump.chapterIndex = chapterIndex;
    jump.offset = offset;
    ReaderJumpRegistry.pending = jump;
  }

  /**
   * 阅读页领取待办；**取走即清空**，重复调用第二次返回 null。
   * 没有待办时返回 null（正常情况，例如用户只是切了后台再回来）。
   */
  static consume(): ReaderJump | null {
    const jump: ReaderJump | null = ReaderJumpRegistry.pending;
    ReaderJumpRegistry.pending = null;
    return jump;
  }
}
