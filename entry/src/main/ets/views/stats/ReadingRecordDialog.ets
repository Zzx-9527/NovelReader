import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { BookReadingRecord } from '../../model/ReadingRecord';

/**
 * 书单区域的最大高度（vp）。
 *
 * ⚠️ **必须是确定数值，不能用 `layoutWeight(1)` + 父级 `maxHeight` 百分比**：
 * 卡片高度是**由内容决定**的（书少时贴合内容、书多时才封顶），
 * 而 `layoutWeight` 只在父容器高度**已确定**时才有余量可分 ——
 * 内容少时它可能算出 0 高度，列表直接消失。
 *
 * 给 `Scroll` 自己一个 vp 上限则没有这个问题：
 *  - 书少 → 高度 = 内容高度（卡片自然变矮）；
 *  - 书多 → 高度封顶，内容溢出后**由它自己内部滚**。
 *
 * ⚠️ 行高约 44vp，取 400 大约显示 9 行，最后一行**故意留半行**：
 * 半行是"下面还有内容"的天然提示，比一个滚动条更安静也更明确。
 */
const LIST_MAX_HEIGHT: number = 400;

/**
 * 「各书时长」弹窗 —— 每本书读了多久的排行列表。
 *
 * ## 版面
 * ```
 *      ┌──────────────────────────────┐
 *      │ ◆ 各书时长    23 本 · 3 时 46 分 │  ← 标题 + 右端合计
 *      │ ──────────────────────────── │
 *      │ 01  仙工开物          1 时 55 分 │  ← 可滚动
 *      │ 02  圣墟                36 分  │
 *      │ 03  玄鉴仙族            20 分  │
 *      └──────────────────────────────┘
 * ```
 *
 * ⚠️⚠️ **刻意不做「时长横条」**（本项目实测的返工，不要再加回来）：
 *
 * 原先每行下面画一条按比例伸缩的横条，但阅读时长是**长尾分布** ——
 * 榜首 1 时 55 分、榜尾 22 秒，线性比例下除榜首外**全部不足 1%**，
 * 被下限钳成一小截贴边的短线。二十几行看起来像**一排没渲染出来的
 * 项目符号**，比不画还糟（用户反馈"布局怪怪的"）。
 *
 * 两条替代方案都更差，所以结论是"不画"：
 *  - **非线性（开方/对数）**能让尾部可见，但会让横条**谎报比例**
 *    （36 分与 1 时 55 分看起来差不多长）—— 图形一旦不忠实就失去了意义；
 *  - **保留线性但去掉下限**，则尾部直接消失成空行。
 *
 * 而时长数字就在右侧、精确到分秒 —— 横条能表达的信息它已经全有了。
 * 判据：**当图形无法忠实表达数据时，去掉图形、留数字。**
 *
 * ⚠️ 配色走 `AppColor`（跟随系统深浅色），与统计页一致 ——
 * 本弹窗属于统计流程，不是阅读页内部（那边才用 `ReaderTheme`）。
 *
 * ⚠️ 回调模型与 `ThemeMenu` 一致：**只有 `onClose`，没有"取消"按钮**。
 * 点遮罩即关闭 —— 再放一行"取消"是同一动作的第二个入口。
 */
@Component
export struct ReadingRecordDialog {
  /**
   * 书单（已按累计时长降序）。
   *
   * ⚠️ 用 `@Prop` 而不是普通成员：数组内容变化时要重绘。
   * 本弹窗每次打开都是**新建**的（父页面用 `if` 条件渲染），
   * 因此拿到的一定是最新快照。
   */
  @Prop books: BookReadingRecord[] = [];
  /** 全部书的累计时长合计（秒）—— 标题右端那句"3 时 46 分" */
  @Prop totalSeconds: number = 0;

  /** 点遮罩（= 关闭） */
  onClose?: () => void;

  build() {
    Stack() {
      // 遮罩：铺满全屏，点了关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.mask)
        .onClick(() => {
          if (this.onClose !== undefined) {
            this.onClose();
          }
        })

      Column() {
        // 顶部一道朱色细线：与 ThemeMenu / ThemeConfirm 同一语汇 —— "印"落在纸上
        Row()
          .width('100%')
          .height(2.5)
          .backgroundColor(AppColor.accent)
          .opacity(0.85)

        /**
         * 标题行：左「各书时长」，右「N 本 · 总时长」。
         *
         * ⚠️ 右端合计是**必须的**：列表被收进弹窗后，页面上那块只剩一个
         * 入口，用户看不到"一共读了多久"。合计放在这里，弹窗自带答案。
         */
        Row() {
          Row({ space: 8 }) {
            /**
             * 朱砂方印：一枚 8vp 的小方块旋转 45°（菱形）——
             * 与 `ThemeMenu` / `ThemeConfirm` 的标题落款完全一致。
             */
            Column()
              .width(8)
              .height(8)
              .backgroundColor(AppColor.accent)
              .opacity(0.9)
              .rotate({ angle: 45 })
              .margin({ top: 1 })

            Text('各书时长')
              .fontSize(AppTheme.FONT_SUBTITLE)
              .fontWeight(FontWeight.Medium)
              .fontFamily(AppFont.titleFamily())
              .letterSpacing(0.5)
              .fontColor(AppColor.textPrimary)
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)

          Text(`${this.books.length} 本 · ${this.totalText()}`)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
            .fontFeature(AppFont.TABULAR)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 15, bottom: 13 })
        .alignItems(VerticalAlign.Center)

        Row()
          .width('100%')
          .height(AppTheme.HAIRLINE)
          .backgroundColor(AppColor.divider)

        /**
         * 书单：**可滚动**，高度上限 `LIST_MAX_HEIGHT`。
         *
         * ⚠️ 上限挂在 `Scroll` 自己身上（`constraintSize.maxHeight`），
         * **不用** `layoutWeight(1)` —— 理由见该常量的说明。
         */
        Scroll() {
          Column() {
            ForEach(this.books, (item: BookReadingRecord, index: number) => {
              Column() {
                if (index > 0) {
                  Row()
                    .width('100%')
                    .height(AppTheme.HAIRLINE)
                    .backgroundColor(AppColor.divider)
                }

                /**
                 * 单行账目：序号 + 书名 + 时长。
                 *
                 * ⚠️ **只有一行、没有第二行**：原先是"书名行 + 横条行"两行，
                 * 横条去掉后自然收成一行，行高从约 66vp 降到约 44vp ——
                 * 同样高度下能多显示一半的书，这正是"布局怪"的另一个来源
                 * （行太胖、一屏看不到几本）。
                 */
                Row({ space: 10 }) {
                  // 序号：像账本的条目编号。固定宽度让所有书名左缘对齐
                  Text(this.rankText(index))
                    .fontSize(11)
                    .fontColor(AppColor.textHint)
                    .fontFeature(AppFont.TABULAR)
                    .width(20)

                  Text(this.titleOf(item))
                    .fontSize(15)
                    .fontColor(AppColor.textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)

                  Text(this.compactDuration(item.seconds))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppColor.textPrimary)
                    .fontFeature(AppFont.TABULAR)
                }
                .width('100%')
                .padding({ left: 18, right: 18, top: 12, bottom: 12 })
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
            }, (item: BookReadingRecord) => `rec_${item.bookId}_${item.seconds}`)
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: LIST_MAX_HEIGHT })
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('84%')
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)
      /**
       * 发丝外框 + 投影：与 ThemeMenu / ThemeConfirm 同一套"纸卡压在页面上"。
       * ⚠️ 背景必须**不透明**（`bgCard`），半透明会让下层统计页透出来。
       */
      .border({ width: AppTheme.HAIRLINE, color: AppColor.divider })
      .shadow({
        radius: 28,
        color: 'rgba(80, 64, 40, 0.28)',
        offsetX: 0,
        offsetY: 10
      })
      .clip(true)
      /**
       * ⚠️ 卡片整体也封顶：`LIST_MAX_HEIGHT` 只约束列表，标题栏还要占
       * 约 50vp。这里给整卡 70% 上限，保证标题与底部都不出屏 ——
       * 与 `ThemeMenu` 的 `constraintSize` 同一个理由。
       */
      .constraintSize({ maxHeight: '70%' })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  // ──────────────────────────────────────────────── 数值与文案

  /** 标题右端的合计文案（"3 时 46 分"） */
  private totalText(): string {
    const h: number = Math.floor(this.totalSeconds / 3600);
    const m: number = Math.floor((this.totalSeconds % 3600) / 60);
    if (h > 0) {
      return `${h} 时 ${m} 分`;
    }
    return `${m} 分`;
  }

  /**
   * 序号（"01" / "02"…）。
   *
   * ⚠️ 补零到两位：一位数与两位数混排时左缘会参差 ——
   * 等宽数字只保证"每个数字等宽"，不保证"位数不同也对齐"。
   */
  private rankText(index: number): string {
    const n: number = index + 1;
    return n < 10 ? `0${n}` : `${n}`;
  }

  /**
   * 书名；连快照都没有时给一句说明。
   *
   * ⚠️ 取不到名字的情况现在只剩**两类历史数据**，都不会再新增：
   *  1. 补 `book_title` 列之前写下的统计行（那时还没有快照这一列）；
   *  2. 补列之前就被删掉的书（书名已随 `book` 行消失，无处可查）。
   *
   * 现在删书会**先把书名回填进统计行**再删（见 `BookRepository.hardDelete`），
   * 因此从这版起，删掉的书仍会显示原来的名字。
   */
  private titleOf(item: BookReadingRecord): string {
    if (item.title.length > 0) {
      return item.title;
    }
    return '已移除的书';
  }

  /**
   * 紧凑时长："4 时 12 分" / "12 分" / "45 秒"。
   *
   * ⚠️ 不复用 `DateUtil.humanizeDuration`：那个返回"4 小时 12 分"，
   * 在账目行右侧这一列会把书名挤短。本弹窗需要**列宽稳定**的短式。
   */
  private compactDuration(seconds: number): string {
    const h: number = Math.floor(seconds / 3600);
    const m: number = Math.floor((seconds % 3600) / 60);
    if (h > 0) {
      return `${h} 时 ${m} 分`;
    }
    if (m > 0) {
      return `${m} 分`;
    }
    return `${seconds} 秒`;
  }
}
