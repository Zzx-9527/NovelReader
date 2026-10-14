import { Book } from '../../model/Book';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { DateUtil } from '../../common/utils/DateUtil';
import { FileUtil } from '../../common/utils/FileUtil';

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

  build() {
    Row({ space: AppTheme.GAP_M }) {
      Column() {
        Text(this.book.title.length > 0 ? this.book.title.substring(0, 1) : '书')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.brand)
      }
      .width(56)
      .height(72)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .backgroundColor(AppColor.brandContainer)
      .justifyContent(FlexAlign.Center)

      Column({ space: 6 }) {
        Text(this.book.title)
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.chapterText())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textSecondary)
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

      Button('继续')
        .fontSize(AppTheme.FONT_CAPTION)
        .height(32)
        .backgroundColor(AppColor.brand)
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
