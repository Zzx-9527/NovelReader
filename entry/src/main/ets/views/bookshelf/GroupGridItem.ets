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
 * ## 关于「N 本」计数的位置（用户明确要求）
 *
 * 计数**不在**网格封面上显示（历史版本试过黑角标、底边标签板两种，
 * 都已移除）：它与组名重复表达"这个组里有什么"，且 9.5vp 的小字
 * 在网格里几乎读不清。数量的展示职责在**分组详情页**的头部副标题 ——
 * 那里有整行宽度，一个 13vp 的「N 本」清清楚楚。
 *
 * ⚠️ 刻意**不加描边**：给整格加 `border` 会让它比同一行的书籍格高 2vp，
 * 网格行高取最大值，于是整行会错开 2vp。
 */
@Component
export struct GroupGridItem {
  @Prop group: BookGroup = new BookGroup();
  onTap?: (group: BookGroup) => void;
  onLongPress?: (group: BookGroup) => void;

  build() {
    Column({ space: 6 }) {
      Column() {
        /**
         * 2×2 封面格。
         *
         * ⚠️ 四边内边距**均匀 6vp**（原来底部 4 是给标签板让位，板已移除）：
         * 格子不贴边，读作"文件夹里露出几张封面"。
         * 「N 本」的计数已挪到**分组详情页**的副标题 —— 封面上的数字
         * 与组名重复表达同一件事，且 9.5vp 的字在网格里几乎读不清。
         */
        Column() {
          GroupCover({ books: this.group.coverBooks })
        }
        .width('100%')
        .height('100%')
        .padding(6)
        .backgroundColor(AppColor.bgCard)
      }
      .width('100%')
      .aspectRatio(3 / 4)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .clip(true)
      .backgroundColor(AppColor.bgCard)

      /**
       * 名称：与书名同一位置与字号，保持网格的整齐；**居中**（用户要求，
       * 与 BookGridItem 的书名同一条中轴）；衬线（探测到才有）+ 字距。
       */
      Text(this.group.name)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.textPrimary)
        .fontFamily(AppFont.titleFamily())
        .letterSpacing(AppTheme.TRACK_NAME)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
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
