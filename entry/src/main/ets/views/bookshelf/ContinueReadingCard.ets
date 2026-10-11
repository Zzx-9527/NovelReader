import { Book } from '../../model/Book';
import { AppTheme } from '../../common/theme/AppTheme';
import { DateUtil } from '../../common/utils/DateUtil';
import { FileUtil } from '../../common/utils/FileUtil';

/** 继续阅读卡片：书架顶部，点击直接进入上次读到的位置 */
@Component
export struct ContinueReadingCard {
  book: Book = new Book();
  onContinue?: (book: Book) => void;

  private chapterText(): string {
    if (this.book.hasNoProgress()) {
      return '还没开始读';
    }
    // 内部 0-based，展示用 1-based
    return `读到第 ${this.book.lastChapterIndex + 1} 章 / 共 ${this.book.totalChapters} 章`;
  }

  build() {
    Row({ space: AppTheme.GAP_M }) {
      Column() {
        Text(this.book.title.length > 0 ? this.book.title.substring(0, 1) : '书')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.PRIMARY)
      }
      .width(56)
      .height(72)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .backgroundColor(AppTheme.PRIMARY_LIGHT)
      .justifyContent(FlexAlign.Center)

      Column({ space: 6 }) {
        Text(this.book.title)
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.chapterText())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .width('100%')

        Row({ space: AppTheme.GAP_S }) {
          Progress({ value: this.book.progressPercent * 100, total: 100 })
            .color(AppTheme.PRIMARY)
            .layoutWeight(1)
            .height(4)
          Text(FileUtil.humanPercent(this.book.progressPercent))
            .fontSize(10)
            .fontColor(AppTheme.TEXT_HINT)
        }
        .width('100%')

        Text(DateUtil.humanize(this.book.lastReadAt))
          .fontSize(10)
          .fontColor(AppTheme.TEXT_HINT)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button('继续')
        .fontSize(AppTheme.FONT_CAPTION)
        .height(32)
        .backgroundColor(AppTheme.PRIMARY)
        .onClick(() => {
          if (this.onContinue !== undefined) {
            this.onContinue(this.book);
          }
        })
    }
    .width('100%')
    .padding(AppTheme.GAP_M)
    .backgroundColor(AppTheme.BG_CARD)
    .borderRadius(AppTheme.CARD_RADIUS)
    .alignItems(VerticalAlign.Center)
  }
}
