import { Book } from '../../model/Book';
import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { DateUtil } from '../../common/utils/DateUtil';
import { FileUtil } from '../../common/utils/FileUtil';
import { BookCover } from './BookCover';

/**
 * 列表模式下的单个书籍项。
 *
 * ⚠️ 必须是 `@Prop`：理由同 `BookGridItem` —— `ForEach` 复用实例时，
 * 普通成员不会拿到刷新后的 `Book`，进度条与"最近阅读"会停在旧值。
 *
 * ## 两种形态（`inset`）
 *
 * 本组件同时服务两个页面，两者的"卡片归属"不同，**不能各写一份**：
 *
 * | 调用处 | `inset` | 样子 |
 * |---|---|---|
 * | 分组详情页（`GroupDetailPage`） | `false`（默认） | 每行自己是一张 `bgCard` 圆角卡，行间靠 `List` 的 8vp 间距分开 |
 * | 书架页列表（`BookShelfPage`） | `true` | 行本身透明，整列外面套**一块** `bgCard`；行与行之间用一根**缩进发丝线**分开 |
 *
 * 为什么书架页要后者：原实现每行一张卡 + 8vp 间距，六行就是"六张卡叠在一起"，
 * 白卡与浅灰底交替出现，整列读起来是碎的。收成一块 + 缩进线之后，
 * 封面那一列连续不断，视觉上"这是一排书"而不是"六个盒子"。
 *
 * ⚠️ 缩进线的左起点是 `AppTheme.LIST_RULE_INSET`(72) = 封面 48 + 间距 12
 * + 内边距 12 —— 正好从**文字列**开始。线若通栏，等于又把整块切成一行行的卡，
 * 白改。改封面尺寸或间距时这个常量要跟着改。
 */
@Component
export struct BookListItem {
  @Prop book: Book = new Book();
  /** 见类注释：`true` = 透明行 + 无圆角，由外层容器提供卡片底 */
  @Prop inset: boolean = false;
  /** 是否在本行**上方**画那根缩进发丝线。首行必须传 `false`，否则线条顶在卡片上边缘 */
  @Prop topRule: boolean = false;
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

  private coverLabel(): string {
    return this.book.title.length > 0 ? this.book.title.substring(0, 1) : '书';
  }

  /** 进度填充宽度。返回百分比字符串，由布局引擎算实际像素（同 `BookCover`） */
  private fillWidth(): string {
    const p: number = this.book.progressPercent;
    const clamped: number = p < 0 ? 0 : (p > 1 ? 1 : p);
    return `${(clamped * 100).toFixed(1)}%`;
  }

  build() {
    /**
     * 外层再套一个 `Column`：只为了把那根缩进发丝线放在**行的上方**
     * 而又让线条自己带上 72vp 的左内边距。
     */
    Column() {
      /**
       * ⚠️ 这根线在 `if` 里，**确实**会让本行高度差 1vp —— 这是有意接受的，
       * 但必须说清为什么它不属于设计文档反复警告的那类"高度随条件变化"：
       *
       *  - 那条纪律针对的是**阅读页**：那里高度变化会触发 `onAreaChange` →
       *    重新分页 → 又改变高度，是个**会自激的环**；
       *  - 这里高度只影响列表行本身，且 `index > 0` 变化必然伴随
       *    `ForEach` 的键变化（键里含进度与内容）⇒ 整列本来就重建一次。
       *    不存在"用户在看着的时候某一行悄悄长高 1vp"的情况，
       *    也没有任何回调会因为这个 1vp 再触发一次布局。
       *
       * 判据：**条件高度只有在会自激、或被用户实时观察到时才是缺陷**；
       * 一行 1vp 的分隔线两者都不占。
       *
       * ⚠️ 不用"给线写 `.margin({left: 72})`"：`.width('100%')` 配左外边距
       * 会让节点整体右移 72vp 并溢出父容器（宽度不会自动减去外边距），
       * 于是线条右端被裁掉。用"外层铺满 + 内层 layoutWeight(1) 吃掉左内边距"
       * 才是宽度守恒的写法。
       */
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
        // 封面：与 BookGridItem 同一套渲染（书脊 / 首字），紧凑排版
        Column() {
          BookCover({ label: this.coverLabel(), compact: true })
        }
        .width(48)
        .height(64)
        .borderRadius(AppTheme.ITEM_RADIUS)
        .clip(true)
        .backgroundColor(AppColor.coverBg)

        Column({ space: 4 }) {
          Text(this.book.title)
            .fontSize(AppTheme.FONT_SUBTITLE)
            .fontColor(AppColor.textPrimary)
            .letterSpacing(AppTheme.TRACK_NAME)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.subtitle())
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
            .fontFeature(AppFont.TABULAR)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          /**
           * 进度：2vp 发丝轨道 + accent 填充 + 等宽百分比。
           *
           * ⚠️ 从 4vp 实心块降到 2vp：4vp 在浅色卡片上是一条"色块"，
           * 会把整行的重量拉到进度条上；2vp 才是"书页上的一条标线"。
           * 轨道用 `divider` 而不是 `cover_text`：这里是页面卡片，
           * 分隔线令牌才是同一个语汇。
           *
           * ⚠️ 轨道**恒显示**（哪怕 0%），与 `BookCover` 上"0% 不画轨道"不同 ——
           * 那里是封面上的装饰，这里是数据行：一行书的信息里
           * "读了多少"必须有位置，否则 0% 的书那一行会缺一块。
           */
          Row({ space: AppTheme.GAP_S }) {
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(AppTheme.RAIL_H)
                .backgroundColor(AppColor.divider)
              Row()
                .width(this.fillWidth())
                .height(AppTheme.RAIL_H)
                .backgroundColor(AppColor.accent)
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
      }
      .width('100%')
      .padding(AppTheme.GAP_M)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    /**
     * ⚠️ 底色与圆角**两种形态共用同一份**（`bgCard` + `ITEM_RADIUS`），
     * 不按 `inset` 分流。
     *
     * 理由是它**本来就看不出来**：`inset` 模式下外层容器也是 `bgCard`
     * 且带 `clip(true)`，行自己再铺一层同色底、加一个同色圆角，
     * 与"不铺"在像素上完全一致（同色不透明，没有接缝也没有透明度叠加）。
     *
     * 反过来，若按 `inset` 分流写成 `Color.Transparent | Resource` 的三元表达式，
     * 就引入了本项目其它地方从未出现过的**混合联合类型** ——
     * 为一个看不见的差别去冒一次编译风险不值得。
     *
     * 判据：**能用"同色叠加"表达的分支，就不要用条件分支表达。**
     */
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
