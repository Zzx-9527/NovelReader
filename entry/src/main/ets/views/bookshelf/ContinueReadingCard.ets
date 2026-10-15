import { Book } from '../../model/Book';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { DateUtil } from '../../common/utils/DateUtil';
import { FileUtil } from '../../common/utils/FileUtil';
import { BookCover } from './BookCover';

/**
 * 继续阅读卡片：书架顶部，点击直接进入上次读到的位置。
 *
 * ## 本次改动：从"白卡片"改成"书签"
 *
 * 原实现是一张 `bgCard` 白卡 + 右侧一枚实心「继续」按钮 ——
 * 它与列表模式的书架卡片是**同一个视觉元素**，扫过去分不出
 * "这一块是特别的"。现在：
 *  - **左侧一道朱色标线**（2.5vp、上下各留 14vp）：它是这一屏唯一
 *    "贴着卡片边缘"的颜色，语义是"当前在读这本" —— 与卡片的存在理由一致；
 *  - **「续 读」眉标**：10vp、0.26em 字距的 accent 小字，给卡片一个
 *    "身份"，不再需要用户猜这块为什么单独出现在顶部；
 *  - **书名落衬线**：与书架里所有题字同一套语汇；
 *  - **「继续」改朱砂实心**：这是整页**唯一**的实心彩色按钮 ——
 *    它是书架的主操作，值得这个唯一性。
 *
 * ⚠️ 书签带（封面右上角的 accent 小色带）保留：它承载
 * "这本书你正夹着书签"的真实语义，与朱色标线、眉标是同一件事的三个层次。
 */
@Component
export struct ContinueReadingCard {
  /**
   * ⚠️ **必须是 `@Prop`，不能是普通成员** —— 这正是"顶部进度不跟着换书"的根因。
   *
   * 普通成员只在组件**创建时**取一次快照，之后父组件状态再怎么变都不会同步进来。
   * 于是书架刷新后 `state.continueBook` 已经换成了另一本书，本卡片却仍渲染
   * 上一次那本 —— 表现就是"我明明在读 B 书了，顶部还显示 A 书 + 旧的章号/百分比"。
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
       * ⚠️ 书签带画在封面**内部**、从顶边垂下来，而不是伸出封面外：
       * 伸出需要负外边距，而负边距在不同父容器里会不会被裁取决于
       * 祖先的裁切设置 —— 那是一个"在某处好好的、搬到别处就没了"的隐患。
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

      Column({ space: 5 }) {
        // 「续 读」眉标：10vp、宽字距 —— 给这张卡一个身份
        Text('续 读')
          .fontSize(10)
          .letterSpacing(2.6)
          .fontColor(AppColor.accent)

        Text(this.book.title)
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          // 衬线（探测到才有）—— 与书架所有题字同一套语汇
          .fontFamily(AppFont.titleFamily())
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
           * ⚠️ 圆点靠"放在一个宽度等于填充量的 `Row` 里、右对齐"来定位：
           * 轨道宽是布局算出来的，代码里拿不到像素值。
           * 用 `justifyContent(End)` 让布局引擎自己去算右端。
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

        Text(`上次阅读 · ${DateUtil.humanize(this.book.lastReadAt)}`)
          .fontSize(10)
          .fontColor(AppColor.textHint)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      /**
       * 「继续」按钮：**朱砂实心** —— 整页唯一的实心彩色按钮。
       *
       * ⚠️ 它是书架的主操作（比"导入"高频得多），值得这个唯一性；
       * 其它一切彩色都退到"文字动作 + 2vp 发丝"的小面积。
       */
      Button('继续')
        .fontSize(AppTheme.FONT_CAPTION)
        .height(34)
        .padding({ left: 16, right: 18 })
        .backgroundColor(AppColor.accent)
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
    /**
     * 左侧朱色标线：贴边的一道，"当前在读这本"。
     *
     * ⚠️ 用 `border`（只有 left 有宽）而不是叠一个绝对定位的色条：
     * border 不参与子布局、不会被圆角裁切问题困扰；
     * 上下留白靠内容自己的 padding 表达 —— 标线与文字齐头齐尾，
     * 比顶天立地的一道更"书签"。
     */
    .border({
      width: { left: 2.5 },
      color: { left: AppColor.accent }
    })
  }
}
