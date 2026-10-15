import { Book } from '../../model/Book';
import { AppColor } from '../../common/theme/AppTheme';
import { BookCover } from './BookCover';

/**
 * 分组封面：**2×2 四个格子，用组内书的封面填**。
 *
 * 行为（用户明确要求）：
 *  - 组里有几本，就填几个格子；空格子留空底；
 *  - 填满 4 格后**不再变化** —— 第 5 本及以后不影响封面；
 *  - 每个格子显示的是那本书的**真封面**（直接复用 `BookCover`，
 *    书脊 + 居中首字 + 题花线，与书架里的书**同一套渲染**，
 *    只隐去右上角百分比 —— 分组封面里的百分比是噪声，用户明确不要）。
 *
 * ⚠️ 这是"文件夹里露出几本书的封面"的意象，**不是**一个静态图标。
 * 早期版本画了一个固定的 4 方块 SVG，那是错的：它永远长一样，
 * 看不出这个分组里有没有书、装的是什么（用户明确指出了这一点）。
 * 中间版本在格子里手写"首字 + 底色"，也已被替换 —— 那份实现与
 * `BookCover` 各画各的，书脊、题花线、字体漂移了也不可知；
 * 复用同一个组件才是"与书一样"的唯一保证（用户明确要求一样）。
 *
 * ⚠️ 格子数固定为 2×2（= 4）。它必须与
 * `AppConstants.GROUP_COVER_SLOTS`（"取几本书"的上限）**保持一致** ——
 * 那个常量决定 ViewModel 取几本，这里决定画几格。
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
   *  - 网格模式封面约 110×147，每格约 50×70 → 首字 14 合适；
   *  - 列表模式封面只有 48×64，每格约 20×30 → 首字 14 会把格子**撑爆**。
   *
   * 透传给 `BookCover.compact`：那边收到后会把首字 27→20、去掉题花线，
   * 与书籍列表小封面完全同一套口径。
   */
  @Prop compact: boolean = false;

  /**
   * 第 `slot` 个格子是否有书。
   *
   * ⚠️ 拆成"有无 + 文字"两个返回**基本类型**的方法，而不是让
   * `bookAt` 返回 `Book | null` 再在 UI 体里判空 ——
   * `@Builder` 的 `Column() { ... }` 里**只能写组件调用**，
   * 不能声明局部变量（`const book = ...` 会直接编译不过）。
   */
  private hasBookAt(slot: number): boolean {
    return slot >= 0 && slot < this.books.length;
  }

  /**
   * 第 `slot` 个格子的封面首字（**单个字**）；空格子返回空串。
   *
   * ⚠️ 格子只有约 50×70，两个字的"仙工"会几乎顶满格子宽（真机实测很难看）；
   * 分组封面里取**单字**，字号由 `glyphSizeAt` 压到 14 —— 与格子的量级匹配。
   * 书架上的正常封面仍是"最多 2 字符"的口径（`BookGridItem.coverLabel`），
   * 两处口径不同是刻意的：格子大小差着四倍。
   */
  private coverLabelAt(slot: number): string {
    if (!this.hasBookAt(slot)) {
      return '';
    }
    const book: Book = this.books[slot];
    const title: string = book.title.length > 0 ? book.title : '书';
    return title.substring(0, 1);
  }

  /** 格子里的首字字号（vp）：网格档 14 / 紧凑档 10，随格子尺寸缩放 */
  private glyphSizeAt(slot: number): number {
    return this.compact ? 10 : 14;
  }

  build() {
    /**
     * 外层用 `Column` + 两个 `Row`（而不是 `Grid`）来排 2×2。
     *
     * ⚠️ 用 `Grid` 也可以，但它会引入自己的滚动/虚拟化语义，
     * 而这里只是 4 个固定格子、不需要滚动。`Row` 嵌套最直白。
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
   * 单个格子：复用 `BookCover`（用户要求与书"一样"）。
   *
   * ⚠️ `BookCover` 是全项目唯一的封面渲染入口 —— 书架网格、列表、
   * 继续阅读卡、分组封面全部走它，书脊/题花线/字体的任何调整
   * 五处同时生效，不会再出现"分组里的封面和书架上的长得不一样"。
   *
   * ⚠️ 与书架封面的**两处刻意差异**（都因为格子只有约 50×70）：
   *  - 首字取**单字**（双字会顶满格子宽，真机实测很难看）；
   *  - `glyphSize` 显式压到 14（默认 27/20 是给 110vp 宽封面用的）。
   *
   * ⚠️ 不传 `percent`（默认 0）：右上角百分比与底部进度发丝都只在
   * percent > 0 时画，0 即"分组封面里这两样都不要"（用户明确不要百分比）。
   */
  @Builder
  coverSlot(slot: number) {
    Column() {
      if (this.hasBookAt(slot)) {
        BookCover({
          label: this.coverLabelAt(slot),
          compact: this.compact,
          glyphSize: this.glyphSizeAt(slot)
        })
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
    .clip(true)
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
