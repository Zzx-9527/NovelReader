import { BookGroup } from '../../model/BookGroup';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { GroupCover } from './GroupCover';

/**
 * 书架首页里的**分组条目**（列表模式）。
 *
 * 与 `GroupGridItem` 是同一内容的两种排版，和 `BookListItem` 对齐
 * （左封面 + 右信息，整行可点）。
 *
 * ⚠️ 尺寸与 `BookListItem` 的封面一致（48×64），否则列表模式下
 * 分组与书的行高不同，混排会显得参差。
 *
 * ⚠️ 必须是 `@Prop`：理由同 `GroupGridItem` ——
 * `ForEach` 复用实例时普通成员拿不到刷新后的 `BookGroup`。
 *
 * ⚠️ `inset` / `topRule` 的语义与 `BookListItem` **完全一致**，
 * 两处必须同步改：书架页把整列收成一块卡片时，分组行与书籍行
 * 用的是同一套"透明行 + 缩进发丝线"。只改一个会立刻看出参差。
 */
@Component
export struct GroupListItem {
  @Prop group: BookGroup = new BookGroup();
  /** 见 `BookListItem.inset` */
  @Prop inset: boolean = false;
  /** 见 `BookListItem.topRule` */
  @Prop topRule: boolean = false;
  onTap?: (group: BookGroup) => void;
  onLongPress?: (group: BookGroup) => void;

  build() {
    Column() {
      if (this.inset && this.topRule) {
        Row() {
          Row()
            .layoutWeight(1)
            .height(AppTheme.HAIRLINE)
            .backgroundColor(AppColor.divider)
        }
        .width('100%')
        .padding({ left: AppTheme.LIST_RULE_INSET })
      }

      Row({ space: AppTheme.GAP_M }) {
        // 封面：与 BookListItem 同尺寸（48×64），保证两种条目行高一致
        Column() {
          /**
           * ⚠️ 传 `compact: true`：列表模式下封面只有 48×64，
           * 每格约 20×30，必须用更小的字号（见 `GroupCover.compact`）。
           */
          GroupCover({ books: this.group.coverBooks, compact: true })
        }
        .width(48)
        .height(64)
        .padding(3)
        .borderRadius(AppTheme.ITEM_RADIUS)
        .backgroundColor(AppColor.bgCard)

        Column({ space: 4 }) {
          Text(this.group.name)
            .fontSize(AppTheme.FONT_SUBTITLE)
            .fontColor(AppColor.textPrimary)
            // 衬线（探测到才有）—— 与 BookListItem 的书名同一套题字语汇
            .fontFamily(AppFont.titleFamily())
            .letterSpacing(AppTheme.TRACK_NAME)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          /**
           * 副标题说明这是分组而不是书。
           *
           * ⚠️ 必须写"分组"二字：列表模式下封面只有一个小图标，
           * 不给文字说明的话用户可能把分组条目误当成一本叫"科幻"的书
           * （网格模式下靠封面图形区分，列表模式下封面太小，辨识度不够）。
           */
          Text(`分组 · ${this.group.bookCount} 本`)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
            .fontFeature(AppFont.TABULAR)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(AppTheme.GAP_M)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    // 底色与圆角两种形态共用（理由见 BookListItem 的同类说明：
    // inset 模式下外层容器同色，行自己再铺一层在像素上完全一致）
    .backgroundColor(AppColor.bgCard)
    .borderRadius(AppTheme.ITEM_RADIUS)
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
