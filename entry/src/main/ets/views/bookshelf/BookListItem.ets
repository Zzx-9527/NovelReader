import { Book } from '../../model/Book';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { DateUtil } from '../../common/utils/DateUtil';
import { FileUtil } from '../../common/utils/FileUtil';

/** 列表模式下的单个书籍项 */
@Component
export struct BookListItem {
  /**
   * ⚠️ 必须是 `@Prop`：理由同 `BookGridItem` —— `ForEach` 复用实例时，
   * 普通成员不会拿到刷新后的 `Book`，进度条与"最近阅读"会停在旧值。
   */
  @Prop book: Book = new Book();
  onTap?: (book: Book) => void;
  onLongPress?: (book: Book) => void;

  private subtitle(): string {
    const parts: string[] = [];
    if (this.book.author.length > 0) {
      parts.push(this.book.author);
    }
    parts.push(`${this.book.totalChapters} 章`);
    parts.push(FileUtil.humanSize(this.book.fileSize));
    return parts.join(' · ');
  }

  build() {
    Row({ space: AppTheme.GAP_M }) {
      // 占位封面
      Column() {
        Text(this.book.title.length > 0 ? this.book.title.substring(0, 1) : '书')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.brand)
      }
      .width(48)
      .height(64)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .backgroundColor(AppColor.brandContainer)
      .justifyContent(FlexAlign.Center)

      Column({ space: 4 }) {
        Text(this.book.title)
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.subtitle())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row({ space: AppTheme.GAP_S }) {
          Progress({ value: this.book.progressPercent * 100, total: 100 })
            .color(AppColor.brand)
            .layoutWeight(1)
            .height(4)
          Text(FileUtil.humanPercent(this.book.progressPercent))
            .fontSize(10)
            .fontColor(AppColor.textHint)
        }
        .width('100%')

        Text(DateUtil.humanize(this.book.lastReadAt))
          .fontSize(10)
          .fontColor(AppColor.textHint)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(AppTheme.GAP_M)
    .backgroundColor(AppColor.bgCard)
    .borderRadius(AppTheme.ITEM_RADIUS)
    .onClick(() => {
      if (this.onTap !== undefined) {
        this.onTap(this.book);
      }
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          if (this.onLongPress !== undefined) {
            this.onLongPress(this.book);
          }
        })
    )
  }
}
