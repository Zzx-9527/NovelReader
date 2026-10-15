import { Book } from '../../model/Book';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { DateUtil } from '../../common/utils/DateUtil';
import { FileUtil } from '../../common/utils/FileUtil';
import { BookCover } from './BookCover';

/** 继续阅读卡片：书架顶部，点击直接进入上次读到的位置 */
@Component
export struct ContinueReadingCard {
  /**
   * ⚠️ **必须是 `@Prop`，不能是普通成员** —— 这正是"顶部进度不跟着换书"的根因。
   *
   * 普通成员只在组件**创建时**取一次快照，之后父组件状态再怎么变都不会同步进来。
   * 于是书架刷新后 `state.continueBook` 已经换成了另一本书，本卡片却仍渲染
   * 上一次那本 —— 表现就是"我明明在读 B 书了，顶部还显示 A 书 + 旧的章号/百分比"。
   * （与设计文档 §5.3 硬约束 1、坑 10「拖动进度条后数字弹回」同源。）
   *
   * `@Prop` 对普通 class 做深拷贝并在父组件状态变化时重新赋值，正是这里要的语义。
   */
  @Prop book: Book = new Book();
  onContinue?: (book: Book) => void;

  private chapterText(): string {
    if (this.book.hasNoProgress()) {
      return '还没开始读';
    }
    // 内部 0-based，展示用 1-based
    return `读到第 ${this.book.lastChapterIndex + 1} 章 / 共 ${this.book.totalChapters} 章`;
  }

  private coverLabel(): string {
    return this.book.title.length > 0 ? this.book.title.substring(0, 1) : '书';
  }

  /** 进度填充宽度。百分比字符串，实际像素交给布局引擎（同 `BookCover`） */
  private fillWidth(): string {
    const p: number = this.book.progressPercent;
    const clamped: number = p < 0 ? 0 : (p > 1 ? 1 : p);
    return `${(clamped * 100).toFixed(1)}%`;
  }

  build() {
    Row({ space: AppTheme.GAP_M }) {
      /**
       * 封面 + **书签带**。
       *
       * ⚠️ 书签带是这张卡片唯一的"装饰"，它承载一个真实语义：
       * "这本书你正夹着书签"（与卡片的存在理由完全一致 —— 它就是"继续阅读"）。
       * 换成纯装饰的色块就会变成 craft 意义上的噪声。
       *
       * ⚠️ 带子画在封面**内部**、从顶边垂下来，而不是伸出封面外：
       * 伸出需要负外边距，而负边距在不同父容器里会不会被裁取决于
       * 祖先的裁切设置 —— 那是一个"在某处好好的、搬到别处就没了"的隐患。
       * 画在里面视觉上一样成立，且确定。
       */
      Stack({ alignContent: Alignment.TopEnd }) {
        BookCover({
          label: this.coverLabel(),
          percent: this.book.progressPercent,
          compact: true
        })

        Column()
          .width(7)
          .height(18)
          .backgroundColor(AppColor.accent)
          .borderRadius({ bottomLeft: 2, bottomRight: 2 })
          // 让开封面右上角，让它读作"夹在书里的一段"而不是一个角标
          .margin({ right: 14 })
      }
      .width(56)
      .height(76)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .clip(true)
      .backgroundColor(AppColor.coverBg)

      Column({ space: 6 }) {
        Text(this.book.title)
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .letterSpacing(AppTheme.TRACK_NAME)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.chapterText())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textSecondary)
          .fontFeature(AppFont.TABULAR)
          .width('100%')

        Row({ space: AppTheme.GAP_S }) {
          /**
           * 进度：2vp 发丝轨道 + accent 填充 + **末梢圆点**。
           *
           * ⚠️ 圆点靠"放在一个宽度等于填充量的 `Row` 里、右对齐"来定位，
           * **不是**靠 `margin` 算偏移：轨道宽是布局算出来的（卡片宽度 − 封面
           * − 按钮 − 间距），代码里拿不到那个像素值。用 `justifyContent(End)`
           * 让布局引擎自己去算右端，任何卡片宽度下都正确。
           *
           * ⚠️ 圆点 6vp 落在 2vp 的轨道里，靠 `alignItems(Center)` 溢出上下各 2vp。
           * 容器没有裁切，所以它会正常画出来 —— 这是刻意的：圆点本该比线粗。
           */
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(AppTheme.RAIL_H)
              .backgroundColor(AppColor.divider)

            Row() {
              Row()
                .width(AppTheme.RAIL_DOT)
                .height(AppTheme.RAIL_DOT)
                .borderRadius(AppTheme.RAIL_DOT / 2)
                .backgroundColor(AppColor.accent)
            }
            .width(this.fillWidth())
            .height(AppTheme.RAIL_H)
            .justifyContent(FlexAlign.End)
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .height(AppTheme.RAIL_H)

          Text(FileUtil.humanPercent(this.book.progressPercent))
            .fontSize(10)
            .fontColor(AppColor.textHint)
            .fontFeature(AppFont.TABULAR)
        }
        .width('100%')

        Text(DateUtil.humanize(this.book.lastReadAt))
          .fontSize(10)
          .fontColor(AppColor.textHint)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      /**
       * 「继续」按钮：**中性填充**（近黑/近白），不是点缀色。
       *
       * ⚠️ `fontColor` 必须显式设成 `onPrimary`：`Button` 的默认字色是白色，
       * 而深色模式下 `primary` 本身接近白色 —— 不设就是"白底白字"，完全看不见。
       */
      Button('继续')
        .fontSize(AppTheme.FONT_CAPTION)
        .height(32)
        .backgroundColor(AppColor.primary)
        .fontColor(AppColor.onPrimary)
        .onClick(() => {
          if (this.onContinue !== undefined) {
            this.onContinue(this.book);
          }
        })
    }
    .width('100%')
    .padding(AppTheme.GAP_M)
    .backgroundColor(AppColor.bgCard)
    .borderRadius(AppTheme.CARD_RADIUS)
    .alignItems(VerticalAlign.Center)
  }
}
