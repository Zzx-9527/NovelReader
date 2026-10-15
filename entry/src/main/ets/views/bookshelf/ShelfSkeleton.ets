import { AppColor, AppTheme } from '../../common/theme/AppTheme';

/**
 * 书架首屏的骨架屏。
 *
 * ## 为什么换掉屏中央的转圈
 *
 * 原来首屏加载时书架正文区正中是一个 `LoadingProgress` + 「正在加载书架…」。
 * 两个问题：
 *  1. 转圈**不传达任何关于内容的信息** —— 用户不知道等待的是"一屏书"
 *     还是"一个错误"，也无法判断大概还要多久；
 *  2. 它出现在**内容区中央**，而内容区马上要被一屏网格填满，
 *     于是必然发生一次"居中元素消失 + 整屏重排"的跳变。
 *
 * 骨架屏按**真实版面**铺占位块（继续阅读卡 + 3×2 封面网格），
 * 于是加载完成时是"占位块被内容替换"，位置不变 —— 零跳变。
 *
 * ## 呼吸动效
 *
 * 1.4 秒、缓入缓出、无限往返的不透明度呼吸（1 → 0.5）。
 *
 * ⚠️ 这是本次重构**唯一新增的动效**，理由是它传达状态（"还在加载"），
 * 而不是装饰。`operate.md` 的原则：动效只服务于状态、反馈、加载、揭示。
 * 若设备上动效被系统"减弱动态效果"设置关掉，不透明度停在 1，
 * 骨架屏退化成静态占位块 —— 依然成立，不依赖动效才能读懂。
 *
 * ⚠️ 用 `cover_bg` 填充占位块，**不新增颜色**：它本来就是"内容未就绪时的
 * 中性底"，与封面占位色是同一个语义，深浅模式下都已调好。
 */
@Component
export struct ShelfSkeleton {
  /**
   * 占位格数量。
   *
   * ⚠️ 取 6（两行三列）而不是 9：整屏铺满会让人以为"书已经在了、只是糊了"，
   * 两行半到两行的量更接近"正在取数据"。而且它必须与网格的
   * `columnsTemplate('1fr 1fr 1fr')` 一致，否则占位与真实版面错位。
   */
  private PLACEHOLDERS: number[] = [0, 1, 2, 3, 4, 5];

  /** 呼吸动效的驱动位：`onAppear` 置 true，属性动画无限往返 */
  @State private dim: boolean = false;

  build() {
    Column({ space: AppTheme.GAP_M }) {
      // ① 继续阅读卡骨架：与真实卡片同尺寸同内边距
      Row({ space: AppTheme.GAP_M }) {
        Column()
          .width(56)
          .height(76)
          .borderRadius(AppTheme.ITEM_RADIUS)
          .backgroundColor(AppColor.coverBg)

        Column({ space: 9 }) {
          Row().width('62%').height(14).borderRadius(4).backgroundColor(AppColor.coverBg)
          Row().width('78%').height(11).borderRadius(6).backgroundColor(AppColor.coverBg)
          Row().width('100%').height(AppTheme.RAIL_H).borderRadius(1).backgroundColor(AppColor.coverBg)
          Row().width(38).height(10).borderRadius(5).backgroundColor(AppColor.coverBg)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row()
          .width(52)
          .height(32)
          .borderRadius(16)
          .backgroundColor(AppColor.coverBg)
      }
      .width('100%')
      .padding(AppTheme.GAP_M)
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)
      .alignItems(VerticalAlign.Center)

      // ② 封面网格骨架：列数、间距、比例与 buildBookList 的网格逐项一致
      Grid() {
        ForEach(this.PLACEHOLDERS, (index: number) => {
          GridItem() {
            Column({ space: 6 }) {
              Column()
                .width('100%')
                .aspectRatio(3 / 4)
                .borderRadius(AppTheme.ITEM_RADIUS)
                .backgroundColor(AppColor.coverBg)

              /**
               * 书名占位条：**统一宽度**。
               *
               * ⚠️ 刻意不做成"有长有短"：参差的条会读成"已经排好版的内容"，
               * 而骨架屏的语义是"这里还没有内容"。统一宽度才诚实。
               */
              Row()
                .width('86%')
                .height(11)
                .borderRadius(6)
                .backgroundColor(AppColor.coverBg)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }, (index: number) => `skeleton_${index}`)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(AppTheme.GAP_M)
      .rowsGap(AppTheme.GAP_M)
      .width('100%')
      /**
       * ⚠️ `layoutWeight(1)`：`Grid` 是**滚动容器**，不给高度时它的行为
       * 取决于父容器，可能撑满也可能塌成 0 —— 而这里是骨架屏，
       * 尺寸必须与真实网格**逐项一致**（真实的那个也是 `layoutWeight(1)`）。
       * 写成同一个约束，加载完成时才不会发生重排。
       */
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })
    /**
     * ⚠️ `layoutWeight(1)` 写在**本组件自己的根节点**上，而不是让调用方
     * 给 `ShelfSkeleton()` 追加属性 —— 自定义组件实例上加通用属性
     * 在 ArkUI 里支持面很窄，写在这里是确定的。
     * 前提：调用方把本组件直接放在一个 `Column` 里（书架页正是如此）。
     */
    .layoutWeight(1)
    .opacity(this.dim ? 0.5 : 1)
    /**
     * ⚠️ `.animation()` 必须写在**它要动画的属性之后**：属性式动画只作用于
     * 它上方的属性。`iterations: -1` + `playMode: Alternate` 让一次
     * 状态翻转变成无限往返的呼吸，因此只需要在 `onAppear` 里翻一次。
     */
    .animation({
      duration: 1400,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    })
    .onAppear(() => {
      this.dim = true;
    })
  }
}
