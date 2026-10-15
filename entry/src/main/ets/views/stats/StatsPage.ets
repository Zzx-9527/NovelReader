import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { StatsService, DayBar } from '../../data/service/StatsService';
import { StatsSummary } from '../../model/DailyStats';
import { DateUtil } from '../../common/utils/DateUtil';
import { Logger } from '../../common/utils/Logger';

/** 折线/柱状图展示最近几天 */
const RECENT_DAYS: number = 7;
/**
 * 绘图区高度（vp）。
 *
 * ⚠️ 它同时是**基线所在的位置**：柱子从这个高度往上长，基线画在它下沿。
 * 于是"最高的一天"正好顶到绘图区顶边，不会超出。
 */
const PLOT_HEIGHT: number = 96;
/** 柱子宽度与圆角（vp） */
const BAR_WIDTH: number = 14;
const BAR_RADIUS: number = 3;
/** 柱间距（vp），必须与标签行的间距一致，否则柱与标签对不齐 */
const BAR_GAP: number = 8;
/**
 * 汇总面板每行的内边距（vp）。
 *
 * ⚠️ 不用 `AppTheme.GAP_M`(12)：统计行只有"标签 + 数值"两个元素，
 * 12 会让四行加起来显得松散，一行 14 竖着看更成一条账。取 14 而不是
 * 新造一个 16，是为了和 `PAGE_PADDING` 区分开 —— 那是页边距，这是行内边距。
 */
const STAT_ROW_PADDING: number = 14;

/**
 * 统计页（书架底部 Tab 第 2 页）。
 *
 * 数据全部来自 `reading_daily_stats` 的 `book_id = 0`（全局哨兵）行，
 * 由 `StatsService.loadSummary()` 一次取齐；柱状图另查最近 7 天明细。
 *
 * ⚠️ 刷新时机：
 *  - `aboutToAppear` 首次加载；
 *  - `@StorageProp(statsVersion)` + `@Watch`：`StatsRepository.addDuration()`
 *    每次落库成功都会 `AppState.bumpStats()`，阅读页回到前台/退出时版本号变化，
 *    这里自动重查 —— 与书架的 `ShelfRefreshRegistry` 同源不同通道，互不干扰。
 *
 * ## 本次改动：四张卡片 → 一块账页
 *
 * 原实现把"今天 / 最近 7 天 / 连续阅读 / 累计阅读"做成 **2×2 四张尺寸完全相同
 * 的卡片**。这是产品界面里最典型的一种模板化写法（大数值 + 小标签 + 点缀色），
 * 它的代价很具体：
 *  - 四张卡各自重复一遍"我是卡片"这件事（圆角、底色、内边距），
 *    而它们本来就是**同一组数据**的四个字段；
 *  - 尺寸相同 ⇒ **没有主次**：用户扫一眼分不出"今天读了多久"和"累计读了多久"
 *    哪个更该看；
 *  - 每张卡里标签在上、数值在下，四个数值不在同一条基线上，
 *    于是四个数字**无法纵向比较**——而这恰恰是统计页最该支持的动作。
 *
 * 现在收成一块 `bgCard` 面板 + 四行：**左标签、右数值、行间发丝线**。
 * 布局本身就把"标签—数值"的对应关系说清了，四个数值右对齐在同一条基线上，
 * 一眼就能纵向比。这不是"更好看"，是**更好读**。
 */
@Component
export struct StatsPage {
  @State summary: StatsSummary = new StatsSummary();
  @State bars: DayBar[] = [];
  @State loading: boolean = true;
  @State error: string = '';
  @StorageProp('statsVersion') @Watch('onStatsChanged') statsVersion: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  /**
   * ⚠️ `@Watch` 回调里不能依赖刚更新的属性值做复杂逻辑，这里只触发重查。
   * 版本号在 0 时（AppStorage 尚未写入）不该触发加载 —— `aboutToAppear` 已加载过，
   * 重复加载会白查一次库。
   */
  onStatsChanged(): void {
    if (this.statsVersion > 0) {
      this.reload();
    }
  }

  private reload(): void {
    this.loading = true;
    this.error = '';
    // 汇总与 7 天明细并行取，互不依赖
    const todayKey: string = DateUtil.today();
    const fromKey: string = DateUtil.shiftDateKey(todayKey, -(RECENT_DAYS - 1));
    StatsService.loadSummary().then((s: StatsSummary) => {
      this.summary = s;
      return StatsService.loadRecentBars(fromKey, todayKey);
    }).then((bars: DayBar[]) => {
      this.bars = bars;
      this.loading = false;
    }).catch((e: Object) => {
      Logger.error('StatsPage', `统计加载失败: ${Logger.errText(e)}`);
      this.error = '统计加载失败，请重试';
      this.loading = false;
    });
  }

  build() {
    Column() {
      /**
       * 标题区。
       *
       * ⚠️ 标题与下面那条线**都带左右内边距**，而线是**通栏**的 ——
       * 所以它们不能共处一个带内边距的容器里：本 `build` 分了三段，
       * 标题自己带内边距、通栏线不带、内容区再自己带。
       * 这与书架页头部是同一套结构，三个主 Tab 的分隔线因此完全对齐。
       */
      Column() {
        Text('统计')
          .fontSize(AppTheme.FONT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .letterSpacing(AppTheme.TRACK_TITLE)
          .width('100%')
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_L })

      // 通栏发丝线：与书架页、我的页同一条语汇
      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)
        .margin({ top: AppTheme.GAP_M })

      if (this.loading) {
        Column({ space: AppTheme.GAP_S }) {
          LoadingProgress().width(36).height(36).color(AppColor.accent)
          Text('加载中…').fontSize(AppTheme.FONT_CAPTION).fontColor(AppColor.textHint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column({ space: AppTheme.GAP_M }) {
          Text(this.error).fontSize(AppTheme.FONT_BODY).fontColor(AppColor.textSecondary)
          Button('重试')
            .fontSize(AppTheme.FONT_BODY)
            .backgroundColor(AppColor.primary)
            .fontColor(AppColor.onPrimary)
            .onClick(() => {
              this.reload();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: AppTheme.GAP_M }) {
            this.buildSummaryPanel()
            this.buildRecentBars()
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .padding({
          left: AppTheme.PAGE_PADDING,
          right: AppTheme.PAGE_PADDING,
          top: AppTheme.GAP_M,
          bottom: AppTheme.GAP_L
        })
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.bgPage)
  }

  /**
   * 汇总面板：一块卡片 + 四行。
   *
   * ⚠️ 四行**内联写死**，不抽带参 `@Builder` ——
   * 设计文档第 15/41 条：带参 `@Builder` 在同一处 `build()` 里被调多次时
   * 参数会串位；"结构相同、文字不同"的小单元必须逐个内联。
   */
  @Builder
  buildSummaryPanel() {
    Column() {
      Row() {
        Text('今天')
          .fontSize(13)
          .fontColor(AppColor.textSecondary)
          // ⚠️ 标签必须吃掉剩余宽度，数值才会被顶到右边缘。
          // 少了这个 layoutWeight，数值会紧跟在标签后面，
          // 四行数值就落在四条不同的横坐标上 —— "纵向可比"这件事当场失效。
          .layoutWeight(1)
        Text(DateUtil.humanizeDuration(this.summary.todaySeconds))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          // 等宽数字：四个数值右对齐后，逐位对齐才谈得上"纵向比较"
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding(STAT_ROW_PADDING)
      .alignItems(VerticalAlign.Bottom)

      Row() {
        Text('最近 7 天')
          .fontSize(13)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
        Text(DateUtil.humanizeDuration(this.summary.weekSeconds))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding(STAT_ROW_PADDING)
      .alignItems(VerticalAlign.Bottom)
      // 行间发丝线用**上边框**表达：只有第二行起才需要，
      // 画成"每行都有的下边框"会让最后一行多出一条悬空的线
      .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })

      Row() {
        Text('连续阅读')
          .fontSize(13)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
        Text(`${this.summary.continuousDays} 天`)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding(STAT_ROW_PADDING)
      .alignItems(VerticalAlign.Bottom)
      .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })

      Row() {
        Text('累计阅读')
          .fontSize(13)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
        Text(DateUtil.humanizeDuration(this.summary.totalSeconds))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding(STAT_ROW_PADDING)
      .alignItems(VerticalAlign.Bottom)
      .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })
    }
    .width('100%')
    .backgroundColor(AppColor.bgCard)
    .borderRadius(AppTheme.CARD_RADIUS)
    .clip(true)
  }

  /**
   * 最近 7 天柱状图。
   *
   * 版面分两段：**绘图区**（含基线）与**标签行**。
   *
   * ⚠️ 为什么把标签拆到绘图区外面，而不是像原来那样每个柱下面挂一个标签：
   * 原来基线没处放 —— 若把基线画在"柱 + 标签"整体之下，它就成了
   * **标签下面的一条横线**（读起来像表格的行线），而不是"柱子从这条线长起来"。
   * 拆开之后基线落在绘图区下沿，语义才对。
   *
   * ⚠️ 两段用**同一个 `layoutWeight(1)` 等分方式**，柱与标签因此天然对齐 ——
   * 不靠写宽度，改列数也不会错位。
   */
  @Builder
  buildRecentBars() {
    Column({ space: 6 }) {
      Text('最近 7 天')
        .fontSize(AppTheme.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      /**
       * 绘图区 + 基线。
       *
       * ⚠️ 基线是绘图区的一个**底部对齐兄弟节点**，不参与柱子的高度计算；
       * 柱子从下往上长（`justifyContent(End)`），最高的一天正好顶到绘图区顶边。
       *
       * ⚠️ 基线画在柱子**之后**（即叠在柱子之上）：
       * `Stack` 的绘制顺序就是子节点顺序，后画的在上层。
       * 反过来先画基线的话，14vp 宽的柱子会把它在自己那一段盖掉，
       * 于是基线变成一条**断断续续的虚线** —— 那不是"基线"，
       * 而是每根柱子下面的一截影子。
       */
      Stack({ alignContent: Alignment.Bottom }) {
        Row({ space: BAR_GAP }) {
          ForEach(this.bars, (bar: DayBar) => {
            Column() {
              /**
               * ⚠️ 今天那根柱子用 `Column` 包一层，把圆点**挖在柱子内部**
               * （柱底 = 圆点，`bgCard` 色），而不是在柱子**上面**另起一个兄弟节点。
               *
               * 兄弟节点的写法有个隐蔽的几何问题：圆点带 `margin top` 时，
               * 外层 `Stack` 的高度会变成 `max(柱高, 圆点+边距)` ——
               * 于是**矮柱子被顶高**，柱底离开基线，看起来像数据不对。
               * 包在柱子里则高度恒等于柱高，圆点画在柱顶内侧。
               *
               * ⚠️ 圆点用 `bgCard` 挖空而不是另加一种颜色：浅色下是
               * "深蓝柱上一点白"，深色下是"浅蓝柱上一点深灰"，
               * 两种模式都成立，且不需要新增任何颜色令牌。
               *
               * ⚠️ `seconds > 0` 才画圆点：0 秒时柱子只有 2vp，
               * 一个 5vp 的圆点会从柱子里溢出来、飘到基线下方。
               */
              if (bar.isToday && bar.seconds > 0) {
                Column() {
                  Row()
                    .width(5)
                    .height(5)
                    .borderRadius(2.5)
                    .backgroundColor(AppColor.bgCard)
                    .margin({ top: 6 })
                }
                .width(BAR_WIDTH)
                .height(this.barHeight(bar.seconds))
                .backgroundColor(AppColor.accent)
                .borderRadius(BAR_RADIUS)
                .alignItems(HorizontalAlign.Center)
              } else {
                Row()
                  .width(BAR_WIDTH)
                  .height(this.barHeight(bar.seconds))
                  .borderRadius(BAR_RADIUS)
                  .backgroundColor(bar.isToday ? AppColor.accent : AppColor.primary)
              }
            }
            .layoutWeight(1)
            .height(PLOT_HEIGHT)
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
          }, (bar: DayBar) => `bar_${bar.label}`)
        }
        .width('100%')
        .height(PLOT_HEIGHT)

        // 基线：画在柱子之后 = 叠在柱子之上，因此是**连续**的一条
        Row()
          .width('100%')
          .height(AppTheme.HAIRLINE)
          .backgroundColor(AppColor.divider)
      }
      .width('100%')
      .height(PLOT_HEIGHT)

      // 标签行：与绘图区同一套等分，因此与柱子逐列对齐
      Row({ space: BAR_GAP }) {
        ForEach(this.bars, (bar: DayBar) => {
          Text(bar.label)
            .fontSize(10)
            .fontColor(bar.isToday ? AppColor.accent : AppColor.textHint)
            .fontWeight(bar.isToday ? FontWeight.Medium : FontWeight.Normal)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
        }, (bar: DayBar) => `label_${bar.label}`)
      }
      .width('100%')

      Text(this.barsHint())
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.textHint)
        .fontFeature(AppFont.TABULAR)
        .width('100%')
    }
    .width('100%')
    .padding(AppTheme.GAP_M)
    .backgroundColor(AppColor.bgCard)
    .borderRadius(AppTheme.CARD_RADIUS)
  }

  /**
   * 柱子高度。
   *
   * ⚠️ 0 秒画一根 **2vp 的短横**而不是不画：不画的话那一天在图上就是"空"，
   * 用户分不清"那天没读"与"数据缺失"。一根贴地的短横明确表达"有这一天，值是 0"。
   * 它的颜色跟柱子一样（今天用 accent），所以"今天还没读"也一眼可见。
   */
  private barHeight(seconds: number): number {
    if (seconds <= 0) {
      return 2;
    }
    let max: number = 0;
    for (const b of this.bars) {
      if (b.seconds > max) {
        max = b.seconds;
      }
    }
    if (max <= 0) {
      return 2;
    }
    // 至少 6vp，让"读过但很少"的日子肉眼可见
    return Math.max(6, Math.round(seconds / max * PLOT_HEIGHT));
  }

  private barsHint(): string {
    let total: number = 0;
    for (const b of this.bars) {
      total += b.seconds;
    }
    if (total <= 0) {
      return '最近 7 天还没有阅读记录，去读一会儿吧';
    }
    return `7 天共 ${DateUtil.humanizeDuration(total)}（累计 ${this.summary.readingDays} 天有阅读记录）`;
  }
}
