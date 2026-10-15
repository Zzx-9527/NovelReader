import { Book } from '../../model/Book';
import { AppColor } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';

/**
 * 分组封面：**2×2 四个格子，用组内书的封面填**。
 *
 * 行为（用户明确要求）：
 *  - 组里有几本，就填几个格子；空格子留空底；
 *  - 填满 4 格后**不再变化** —— 第 5 本及以后不影响封面；
 *  - 每个格子显示的是那本书的封面（TXT 没有封面，用"书名首字 + 中性底色"，
 *    与 `BookGridItem` / `BookListItem` 的占位封面**同一套口径**）。
 *
 * ⚠️ 这是"文件夹里露出几本书的封面"的意象，**不是**一个静态图标。
 * 早期版本画了一个固定的 4 方块 SVG，那是错的：它永远长一样，
 * 看不出这个分组里有没有书、装的是什么（用户明确指出了这一点）。
 *
 * ⚠️ 格子数固定为 2×2（= 4）。它必须与
 * `AppConstants.GROUP_COVER_SLOTS`（"取几本书"的上限）**保持一致** ——
 * 那个常量决定 ViewModel 取几本，这里决定画几格。
 * 两者不同就会出现"取了 4 本却画 6 格"（或反之）。
 * 这里没有把 4 抽成参数，是因为 2×2 的布局是写死的四行结构，
 * 真正需要同步的是**取数上限**，而它已经由常量统一。
 */
@Component
export struct GroupCover {
  /**
   * 组内前几本书（最多 `GROUP_COVER_SLOTS` 本）。
   *
   * ⚠️ 必须是 `@Prop`：`ForEach` 复用组件实例时，普通成员只在创建时快照，
   * 拿不到刷新后的数组 —— 封面会停在上一次的书的组合上。
   */
  @Prop books: Book[] = [];
  /**
   * 是否**紧凑**渲染（列表模式的小封面）。
   *
   * ⚠️ 必须有这个区分，不能只靠字号自适应：
   *  - 网格模式封面约 110×147，每格约 50×70 → 字号 14 合适；
   *  - 列表模式封面只有 48×64，每格约 20×30 → 字号 14 会把格子**撑爆**
   *    （首字超出格子、甚至把布局挤变形）。
   *
   * 同一个组件承载两种尺寸，就必须让调用方告诉它"你现在有多小" ——
   * 靠写死一个字号是做不到的（这也是 `GroupCover` 复用而非复制两份的代价，
   * 但这个代价只是一行分支，远小于维护两套封面逻辑）。
   */
  @Prop compact: boolean = false;

  /**
   * 第 `slot` 个格子是否有书。
   *
   * ⚠️ 拆成"有无 + 文字"两个返回**基本类型**的方法，而不是让
   * `bookAt` 返回 `Book | null` 再在 UI 体里判空 ——
   * `@Builder` 的 `Column() { ... }` 里**只能写组件调用**，
   * 不能声明局部变量（`const book = ...` 会直接编译不过）。
   * 这是本项目在别处踩过的同一类约束：UI 体不是普通函数体。
   */
  private hasBookAt(slot: number): boolean {
    return slot >= 0 && slot < this.books.length;
  }

  /**
   * 第 `slot` 个格子的占位封面字（书名首字）；空格子返回空串。
   *
   * ⚠️ 空串时**不渲染 `Text`**（见 `coverSlot`）：渲染一个空 `Text`
   * 虽看不见，但会多出一个无意义节点。调用点用 `hasBookAt` 判断。
   */
  private coverLabelAt(slot: number): string {
    if (!this.hasBookAt(slot)) {
      return '';
    }
    const book: Book = this.books[slot];
    const title: string = book.title.length > 0 ? book.title : '书';
    return title.substring(0, 1);
  }

  build() {
    /**
     * 外层用 `Column` + 两个 `Row`（而不是 `Grid`）来排 2×2。
     *
     * ⚠️ 用 `Grid` 也可以，但它会引入自己的滚动/虚拟化语义，
     * 而这里只是 4 个固定格子、不需要滚动。`Row` 嵌套最直白，
     * 也不会在"父容器高度由 aspectRatio 决定"时出现行高算不出来的问题。
     *
     * ⚠️ 四个格子**内联写死**，不抽带参 `@Builder`：
     * 设计文档第 15/41 条 —— 带参 `@Builder` 在同一处 `build()` 里
     * 调多次会**参数串位**。这里恰好要调 4 次，正是那个坑的高发场景。
     */
    Column({ space: SLOT_GAP }) {
      Row({ space: SLOT_GAP }) {
        this.coverSlot(0)
        this.coverSlot(1)
      }
      .width('100%')
      .layoutWeight(1)

      Row({ space: SLOT_GAP }) {
        this.coverSlot(2)
        this.coverSlot(3)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 单个格子。
   *
   * ⚠️ 带一个**下标**参数。带参 `@Builder` 有"同处多次调用参数串位"的风险，
   * 但这里每次调用都是独立的 `Row` 子节点、参数只有下标一个数字，
   * 且格子内容一律**由下标现算**（不再从外部传书名/颜色等多个参数），
   * 串位无从发生。
   */
  @Builder
  coverSlot(slot: number) {
    Column() {
      if (this.hasBookAt(slot)) {
        Text(this.coverLabelAt(slot))
          // 紧凑模式（列表小封面）用小字号，否则会把格子撑爆
          .fontSize(this.compact ? 10 : 14)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.coverText)
          /**
           * ⚠️ 字体族与 `BookCover` 的封面首字**必须同源**（`AppFont.titleFamily()`）：
           * 分组封面里露出的就是组内那几本书的首字，字体不一致会一眼看出
           * "同一个字在分组里和书上长得不一样"。
           */
          .fontFamily(AppFont.titleFamily())
      }
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    /**
     * ⚠️ 有书的格子用 `coverBg`（与书籍占位封面同色），
     * 空格子用 `bgCard` —— 两者必须能区分，
     * 否则空分组看起来像装了 4 本灰书。
     */
    .backgroundColor(this.hasBookAt(slot) ? AppColor.coverBg : AppColor.bgCard)
    .borderRadius(SLOT_RADIUS)
  }
}

/**
 * 格子之间的间隙与圆角（vp）。
 *
 * ⚠️ 取小值：封面整体只有几十 vp 宽，每个格子约 20~30vp，
 * 间隙再大就会把格子挤得看不清内容。
 */
const SLOT_GAP: number = 3;
const SLOT_RADIUS: number = 3;
