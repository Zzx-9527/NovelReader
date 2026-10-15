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
/** 柱子宽度与圆角（vp）。
 *
 * ⚠️ 14 → 11：粗柱无网格像仪表盘，细柱带网格像账簿（见 buildRecentBars）。
 */
const BAR_WIDTH: number = 11;
const BAR_RADIUS: number = 2.5;
/** 柱间距（vp），必须与标签行的间距一致，否则柱与标签对不齐 */
const BAR_GAP: number = 8;
/** 绘图区顶部往下画几道水平网格线（含基线之外的参考线） */
const GRID_LINES: number = 3;
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
 * ## 本次改动：一块账页 → 一个主数值 + 账目行
 *
 * 上一版把四项收成"一块面板 + 四行"，判断是对的（数值右对齐、纵向可比）。
 * 这一版再进一步，把**层级**做出来：
 *  - 「今天」是用户打开这一页最想看的数 —— 把它**拎出来**做 54vp 的
 *    衬线主数值，单位（时/分）用衬线小字缀在后面；
 *  - 其余三项（最近 7 天 / 连续阅读 / 累计阅读）退成**账目行**：
 *    无卡片、只有发丝线，左标签右数值 —— "账"的意象；
 *  - 柱状图收细（14→11vp）并加**水平网格线**：粗柱无网格像仪表盘，
 *    细柱带网格像账簿；柱顶补数值，不用心算柱高。
 *
 * ⚠️ 主数值不放卡片、不铺底：它本身就是版面的主角，
 * 套一层卡反而把"这是最重要的一件事"稀释成"又一个面板"。
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
          Column({ space: AppTheme.GAP_L }) {
            this.buildLede()
            this.buildRecentBars()
            this.buildLedger()
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
   * 主数值：今天读了多久。
   *
   * ⚠️ 数字与单位分开渲染：数字 54vp、单位衬线 17vp 各自取色，
   * 比"塞在一个字符串里靠字号统一"干净 —— 单位小一号是排印惯例。
   * `humanizeDuration` 的输出格式（"X时Y分"）在这里拆开。
   */
  @Builder
  buildLede() {
    Row() {
      Column({ space: 6 }) {
        Text('今 日')
          .fontSize(11)
          .letterSpacing(2.6)
          .fontColor(AppColor.textHint)

        Row({ space: 2 }) {
          Text(this.ledeNumber())
            .fontSize(54)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .fontFeature(AppFont.TABULAR)
            // 大数字配衬线才有"刊头"的味道；取不到衬线自动回退系统字体
            .fontFamily(AppFont.titleFamily())

          Text(this.ledeUnit())
            .fontSize(17)
            .fontColor(AppColor.textSecondary)
            .fontFamily(AppFont.titleFamily())
            .margin({ left: 4, bottom: 8 })
        }
        .alignItems(VerticalAlign.Bottom)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 右下角缀连续天数：今天这一格"读没读"的第二个信号
      Text(`连续 ${this.summary.continuousDays} 天`)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.accent)
        .fontFeature(AppFont.TABULAR)
        .alignSelf(ItemAlign.End)
        .padding({ bottom: 10 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
  }

  /** 主数值的数字部分（"1时24分" → "1:24" 不好读，直接拆"时/分"两段取主段） */
  private ledeNumber(): string {
    return `${this.summary.todaySeconds / 3600 >= 1
      ? Math.floor(this.summary.todaySeconds / 3600)
      : Math.floor(this.summary.todaySeconds / 60)}`;
  }

  /** 主数值的单位部分（时 / 分） */
  private ledeUnit(): string {
    return this.summary.todaySeconds / 3600 >= 1 ? '时' : '分';
  }

  /**
   * 账目行：最近 7 天 / 连续阅读 / 累计阅读 / 有记录天数。
   *
   * ⚠️ 三行**内联写死**，不抽带参 `@Builder` ——
   * 设计文档第 15/41 条：带参 `@Builder` 在同一处 `build()` 里被调多次时
   * 参数会串位；"结构相同、文字不同"的小单元必须逐个内联。
   *
   * ⚠️ 无卡片、无底色：账目行不需要容器，只有发丝线 ——
   * 主数值已经承担了版面重量，这里越轻越好。
   */
  @Builder
  buildLedger() {
    Column() {
      Row() {
        Text('最近 7 天')
          .fontSize(13)
          .fontColor(AppColor.textSecondary)
          // ⚠️ 标签必须吃掉剩余宽度，数值才会被顶到右边缘
          .layoutWeight(1)
        Text(DateUtil.humanizeDuration(this.summary.weekSeconds))
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Bottom)
      .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })

      Row() {
        Text('连续阅读')
          .fontSize(13)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
        Text(`${this.summary.continuousDays} 天`)
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Bottom)
      .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })

      Row() {
        Text('累计阅读')
          .fontSize(13)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
        Text(DateUtil.humanizeDuration(this.summary.totalSeconds))
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Bottom)
      .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })

      Row() {
        Text('有记录的天数')
          .fontSize(13)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
        Text(`${this.summary.readingDays} 天`)
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .alignItems(VerticalAlign.Bottom)
      .border({
        width: { top: AppTheme.HAIRLINE, bottom: AppTheme.HAIRLINE },
        color: AppColor.divider
      })
    }
    .width('100%')
  }

  /**
   * 最近 7 天柱状图。
   *
   * 版面分两段：**绘图区**（含水平网格线与基线）与**标签行**。
   *
   * ⚠️ 为什么把标签拆到绘图区外面：基线必须落在绘图区下沿，
   * "柱子从这条线长起来"的语义才对（拆开的理由上一版已论证，保留）。
   *
   * ⚠️ 两段用**同一个 `layoutWeight(1)` 等分方式**，柱与标签因此天然对齐。
   *
   * ## 本次改动：加水平网格线 + 柱顶数值
   *
   *  - 三道淡网格线（`rule-soft` 用 `divider` 低不透明度近似）把绘图区分成
   *    四档，柱高有参照 —— 账簿的意象，而不是仪表盘；
   *  - 柱顶补数值（分钟数，0 显示 "0"）：不用心算柱高。
   *    数值用 9.5vp 的 hint 色，不与柱子抢；
   *  - 柱宽 14 → 11。
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
       * 绘图区：网格线画在**柱子之下**（先画）——
       * 网格是背景参照，柱子是数据；反过来柱子会被线"切"。
       * 基线仍画在**柱子之后**（叠在柱子上），保证是连续的一条。
       */
      Stack({ alignContent: Alignment.Bottom }) {
        // ① 水平网格线：三道淡线 + 底部基线位置留空（基线单独画）
        Column() {
          ForEach(this.gridLineKeys(), (_: string, idx: number) => {
            Row()
              .width('100%')
              .height(AppTheme.HAIRLINE)
              .backgroundColor(AppColor.divider)
              .opacity(0.5)
              .margin({ bottom: (PLOT_HEIGHT / (GRID_LINES + 1)) - 1 })
          }, (k: string) => k)
        }
        .width('100%')
        .height(PLOT_HEIGHT - 22)
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)

        // ② 柱子
        Row({ space: BAR_GAP }) {
          ForEach(this.bars, (bar: DayBar) => {
            Column() {
              // 柱顶数值：分钟数（0 也画，"那天没读"本身是信息）
              Text(`${Math.round(bar.seconds / 60)}`)
                .fontSize(9.5)
                .fontColor(bar.isToday ? AppColor.accent : AppColor.textHint)
                .fontFeature(AppFont.TABULAR)
                .margin({ bottom: 4 })

              /**
               * ⚠️ 今天那根柱子把圆点**挖在柱子内部**（柱顶 = 圆点，`bgCard` 色）：
               * 兄弟节点写法会把矮柱子顶高、柱底离开基线（上一版论证过，保留）。
               */
              if (bar.isToday && bar.seconds > 0) {
                Column() {
                  Row()
                    .width(4)
                    .height(4)
                    .borderRadius(2)
                    .backgroundColor(AppColor.bgCard)
                    .margin({ top: 5 })
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
            /**
             * ⚠️ 柱列改成"数值在柱上方"的纵排：
             * justifyContent(End) 把"数值 + 柱"压到底部，数值自然浮在柱顶。
             */
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
          }, (bar: DayBar) => `bar_${bar.label}`)
        }
        .width('100%')
        .height(PLOT_HEIGHT)

        // ③ 基线：画在柱子之后 = 叠在柱子之上，因此是**连续**的一条
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
   * 网格线的 ForEach 键。
   *
   * ⚠️ `ForEach` 需要一个数组；网格线是纯装饰、条数固定，
   * 生成 ["g0","g1","g2"] 这样无意义的键即可，渲染时不用键的内容。
   */
  private gridLineKeys(): string[] {
    const keys: string[] = [];
    for (let i = 0; i < GRID_LINES; i++) {
      keys.push(`grid_${i}`);
    }
    return keys;
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
