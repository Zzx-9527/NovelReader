import { BookGroup } from '../../model/BookGroup';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { GroupCover } from './GroupCover';

/**
 * 书架首页里的**分组条目**（网格模式）。
 *
 * 视觉上刻意做成"一本书"：与 `BookGridItem` 同一套尺寸（3:4 封面、
 * 下方两行书名），所以它混在书籍网格里毫无违和感 ——
 * 用户看到的是一排"封面"，其中几张是文件夹（用户明确要求如此）。
 *
 * ⚠️ 封面是**动态的**：由 `GroupCover` 用**组内前几本书的封面**填 2×2 四个格子，
 * 有几本填几格、填满 4 格后不再变化（用户明确要求）。
 *
 * ⚠️ 早期版本这里放了一个**固定的 4 方块 SVG**（`group_cover.svg`），
 * 那是错的：它永远长一样，看不出这个分组里有没有书、装的是什么。
 * 那个 SVG 已删除，别再引回来 —— 分组封面必须反映**组内的真实内容**。
 *
 * ⚠️ 与 `BookGridItem` 一样，`group` 必须用 `@Prop`：
 * `ForEach` 的键是 `group.id`，刷新后键不变 ⇒ ArkUI 会**复用**组件实例，
 * 普通成员只在创建时快照，复用时就拿不到新的 `BookGroup` ——
 * 组名改了、数量变了、封面里的书换了都不会更新。
 *
 * ## 本次改动：数量从"黑角标"改成"标签板"
 *
 * 原实现把「3 本」做成右下角的黑底角标（`mask` + `onScrim`）压在 2×2 封面上。
 * 两个问题：① 它是**压在内容上的深色块**，一屏出现两三次之后整片网格变脏；
 * ② 它和书籍封面上的进度角标是同一个视觉元素，于是"分组"和"书"在缩略图上
 * 分不出来 —— 而这两者恰恰是最需要区分的。
 *
 * 现在改成封面**底边的一条标签板**：蓝色（`coverBg`）底 + `coverText` 文字。
 * 于是封面内部天然出现"内容区 / 标签区"两段，与书籍封面（整片纸 + 书脊）
 * 一眼可分。这条板只占 18vp，2×2 的格子从 43×60 变成 43×52 ——
 * 首字字号仍是 14，实测这个尺寸下不会撑爆。
 *
 * ⚠️ 刻意**不加描边**：给整格加 `border` 会让它比同一行的书籍格高 2vp，
 * 网格行高取最大值，于是整行会错开 2vp。用"底色分段"而不是"线条"
 * 来表达结构，正好绕开这个几何问题，也不需要新增颜色（`coverBg` 是既有令牌）。
 */
@Component
export struct GroupGridItem {
  @Prop group: BookGroup = new BookGroup();
  onTap?: (group: BookGroup) => void;
  onLongPress?: (group: BookGroup) => void;

  build() {
    Column({ space: 6 }) {
      Column() {
        // 上半：2×2 封面格。四边内边距让格子不贴边，读作"文件夹里露出几张封面"
        Column() {
          GroupCover({ books: this.group.coverBooks })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 6, right: 6, top: 6, bottom: 4 })
        .backgroundColor(AppColor.bgCard)

        /**
         * 下半：标签板。
         *
         * ⚠️ 外面套 `Row` 而不是给 `Text` 写 `height` + `textAlign`：
         * `Text` 在自己被撑高之后文字靠上对齐，看起来是"顶在板上"；
         * `Row` + `justifyContent/alignItems` 才是确定的垂直居中。
         */
        Row() {
          Text(`${this.group.bookCount} 本`)
            .fontSize(9.5)
            .fontColor(AppColor.coverText)
            // 数量会随整理变化，等宽数字让它在刷新时不会左右微跳
            .fontFeature(AppFont.TABULAR)
        }
        .width('100%')
        .height(18)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(AppColor.coverBg)
      }
      .width('100%')
      .aspectRatio(3 / 4)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .clip(true)
      .backgroundColor(AppColor.bgCard)

      // 名称：与书名同一位置与字号，保持网格的整齐
      Text(this.group.name)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.textPrimary)
        .letterSpacing(AppTheme.TRACK_NAME)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .onClick(() => {
      if (this.onTap !== undefined) {
        this.onTap(this.group);
      }
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          if (this.onLongPress !== undefined) {
            this.onLongPress(this.group);
          }
        })
    )
  }
}
