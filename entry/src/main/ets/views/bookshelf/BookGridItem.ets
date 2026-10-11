import { Book } from '../../model/Book';
import { AppTheme } from '../../common/theme/AppTheme';
import { FileUtil } from '../../common/utils/FileUtil';

/**
 * 网格模式下的单个书籍项。
 *
 * 封面暂用"书名首字 + 渐变色块"占位 —— TXT 没有封面，
 * 后续接入 EPUB 封面时只需替换这部分的渲染。
 */
@Component
export struct BookGridItem {
  book: Book = new Book();
  onTap?: (book: Book) => void;
  onLongPress?: (book: Book) => void;

  /** 用书名首字做占位封面的字，最多取 2 个字符 */
  private coverLabel(): string {
    const title: string = this.book.title.length > 0 ? this.book.title : '书';
    return title.substring(0, title.length >= 2 ? 2 : 1);
  }

  build() {
    Column({ space: 6 }) {
      Stack() {
        // 封面占位：书名首字 + 浅色底。
        //
        // TODO(EPUB/封面)：接入真实封面时用 `Image(absolutePath)` ——
        // ArkUI 的 Image 支持沙箱文件路径，但**不支持空字符串**（会抛错），
        // 所以这里先只做占位，不做无效分支。
        Column() {
          Text(this.coverLabel())
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppTheme.PRIMARY)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(AppTheme.PRIMARY_LIGHT)

        // 阅读进度角标
        if (this.book.progressPercent > 0) {
          Text(FileUtil.humanPercent(this.book.progressPercent))
            .fontSize(10)
            .fontColor(AppTheme.TEXT_ON_PRIMARY)
            .backgroundColor(AppTheme.BG_MASK)
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .position({ right: 4, bottom: 4 })
        }
      }
      .width('100%')
      .aspectRatio(3 / 4)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .clip(true)
      .backgroundColor(AppTheme.BG_CARD)

      Text(this.book.title)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.TEXT_PRIMARY)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
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
