import { Book } from '../../model/Book';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { BookCover } from './BookCover';

/**
 * 网格模式下的单个书籍项。
 *
 * 封面本体已抽到 `BookCover`（书脊 / 题花线 / 底部进度发丝都在那里，
 * 三种尺寸共用一份）。本组件只负责**尺寸与外部形状**：
 * 3:4 的比例、8vp 圆角、裁切，以及封面下方的书名。
 *
 * ⚠️ 尺寸与裁切留在本组件、而不是下沉到 `BookCover`，是刻意的分工：
 * `BookCover` 被列表（48×64）与继续阅读卡（56×76）复用，
 * 那两处的比例**不是** 3:4（64/48=1.333、76/56=1.357）。若把
 * `aspectRatio(3/4)` 写进 `BookCover`，列表封面就会被强行拉成 3:4 而变形。
 * 所以：**组件管画什么，容器管多大**。
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

  /** 用书名首字做占位封面的字，最多取 2 个字符（`BookCover` 的首字口径） */
  private coverLabel(): string {
    const title: string = this.book.title.length > 0 ? this.book.title : '书';
    return title.substring(0, title.length >= 2 ? 2 : 1);
  }

  build() {
    Column({ space: 6 }) {
      /**
       * 封面容器：比例、圆角、裁切三件事都在这里。
       *
       * ⚠️ 底色用 `coverBg` 而不是原来的 `bgCard`：`BookCover` 自己不画底，
       * 万一有半个像素的缝，露出的应该是"纸色"而不是"卡片白"。
       *
       * ⚠️ `clip(true)` 是书脊与进度发丝能贴到圆角里的前提 ——
       * 少了它，3vp 书脊会是一条方角的直边，从圆角处戳出来。
       */
      Stack() {
        BookCover({
          label: this.coverLabel(),
          percent: this.book.progressPercent
        })
      }
      .width('100%')
      .aspectRatio(3 / 4)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .clip(true)
      .backgroundColor(AppColor.coverBg)

      /**
       * 书名：**居中**（用户要求）—— 与封面的居中首字同一条中轴，
       * 网格里三列的名字都落在各自列的中心，扫读时是对齐的。
       */
      Text(this.book.title)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.textPrimary)
        // 书名在密集网格里，字距只加一点点；再大就会让三列标题失去对齐感
        .letterSpacing(AppTheme.TRACK_NAME)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
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
