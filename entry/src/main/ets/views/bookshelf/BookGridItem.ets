import { Book } from '../../model/Book';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { FileUtil } from '../../common/utils/FileUtil';

/**
 * 网格模式下的单个书籍项。
 *
 * 封面暂用"书名首字 + 渐变色块"占位 —— TXT 没有封面，
 * 后续接入 EPUB 封面时只需替换这部分的渲染。
 */
@Component
export struct BookGridItem {
  /**
   * ⚠️ 必须是 `@Prop`：`ForEach` 的键是 `book.id`，刷新后键不变 ⇒ ArkUI 会**复用**
   * 组件实例。普通成员只在创建时快照，复用时就拿不到新的 `Book` ——
   * 进度角标、阅读时间会一直停在上一次加载的值（同 `ContinueReadingCard`）。
   */
  @Prop book: Book = new Book();
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
        // 封面占位：书名首字 + **中性**底色（不用点缀色）。
        //
        // ⚠️ 一屏同时有 6~9 个封面，用主题色会把整片网格染成一块同色，
        // 书名反而看不清 —— 主题色只留给小面积元素（见 AppColor.accent 的说明）。
        //
        // TODO(EPUB/封面)：接入真实封面时用 `Image(absolutePath)` ——
        // ArkUI 的 Image 支持沙箱文件路径，但**不支持空字符串**（会抛错），
        // 所以这里先只做占位，不做无效分支。
        Column() {
          Text(this.coverLabel())
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.coverText)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(AppColor.coverBg)

        // 阅读进度角标。
        //
        // ⚠️ 底色是 `mask`（两种模式下都是黑），所以字色必须用 `onScrim`
        // 而不是 `textPrimary` —— 后者在浅色模式下是近黑，会变成"黑底黑字"。
        if (this.book.progressPercent > 0) {
          Text(FileUtil.humanPercent(this.book.progressPercent))
            .fontSize(10)
            .fontColor(AppColor.onScrim)
            .backgroundColor(AppColor.mask)
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .position({ right: 4, bottom: 4 })
        }
      }
      .width('100%')
      .aspectRatio(3 / 4)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .clip(true)
      .backgroundColor(AppColor.bgCard)

      Text(this.book.title)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.textPrimary)
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
