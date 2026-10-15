import { BookGroup } from '../../model/BookGroup';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
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
 */
@Component
export struct GroupGridItem {
  @Prop group: BookGroup = new BookGroup();
  onTap?: (group: BookGroup) => void;
  onLongPress?: (group: BookGroup) => void;

  build() {
    Column({ space: 6 }) {
      Stack() {
        /**
         * 封面：**2×2 四个格子，用组内书的封面填**（见 `GroupCover`）。
         *
         * ⚠️ 不是静态图标 —— 组里有几本填几格，填满 4 格后不再变化。
         * 早期版本放了一个固定的 4 方块 SVG，永远长一样，
         * 看不出这个分组里有没有书（用户明确指出了这一点）。
         *
         * ⚠️ 外层给一点内边距：四个格子直接铺满会显得很挤，
         * 留出边距后更像"文件夹里露出几张封面"。
         */
        Column() {
          GroupCover({ books: this.group.coverBooks })
        }
        .width('100%')
        .height('100%')
        .padding(6)
        .backgroundColor(AppColor.bgCard)

        /**
         * 书籍数量角标。
         *
         * ⚠️ 底色用 `mask`（两种模式下都是黑），字色必须用 `onScrim` ——
         * 与 `BookGridItem` 的进度角标同一个理由：`textPrimary` 在浅色模式下
         * 是近黑，配黑底就是"黑底黑字"看不见。
         */
        Text(`${this.group.bookCount} 本`)
          .fontSize(10)
          .fontColor(AppColor.onScrim)
          .backgroundColor(AppColor.mask)
          .borderRadius(4)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .position({ right: 4, bottom: 4 })
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
