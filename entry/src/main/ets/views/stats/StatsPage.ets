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
/** 柱子宽度与圆角（vp）。细柱带网格像账簿（效果稿的样式）。 */
const BAR_WIDTH: number = 11;
const BAR_RADIUS: number = 2.5;
/** 柱间距（vp），必须与标签行的间距一致，否则柱与标签对不齐 */
const BAR_GAP: number = 8;
/** 绘图区顶部往下画几道水平网格线（基线之外的参考线） */
const GRID_LINES: number = 3;
const WEEKDAY_NAMES: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
/** 热力图窗口（天）—— 近三个月，GitHub contributions 的量级与方向 */
const HEAT_DAYS: number = 90;
/** 热力图小格边长与间距（vp）。格宽由 layoutWeight 等分铺满，边长只约束高度 */
const HEAT_GAP: number = 3;

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
 * ## 版面（与效果稿逐元素对齐 + 本次扩充）
 *
 * ```
 * 统计
 * 2025 年 6 月 12 日 · 星期四          ← 日期副标题
 * ──────────────────────────────
 * 1时 24 分              今 日
 *                     比昨天多 12 分   ← 主数值 + 右侧两行眉标
 *
 * 最近七日     共 6 时 08 分  ← 段标题（右端七天合计）
 *  ▁ ▂ ▃ ▅ ▆ █            （无卡片、带网格线与柱顶数值）
 * 周五 周六 …                今天
 *
 * ◆ 最近三个月  共 8 时 12 分  ← 热力图（横向满宽：列=周、行=周一~周日）
 *   ▦▦▦▦▦▦▦▦▦▦▦▦▦            左旧右今，四档朱砂色阶
 *   ▦▦▦▦▦▦▦▦▦▦▦▦▦
 *   ▦▦▦▦▦▦▦▦▦▦▦▦▦
 *                少 ▪▪▪▪ 多
 *
 * 连续阅读                 17 天    ← 账目行：发丝线分隔、无卡片
 * 累计阅读              42 时 18 分
 * 有记录的天数              63 天
 *
 * ◆ 书架                          ← 书架总览（2×2 无框格）
 *   书 6 本   字 182 万
 *   读 3 本   毕 1 本
 *
 * ◆ 标注                          ← 标注统计（三行账目）
 *   书签 12 条
 *   划线 30 条
 *   笔记 5 条
 * ```
 */
@Component
export struct StatsPage {
  @State summary: StatsSummary = new StatsSummary();
  @State bars: DayBar[] = [];
  /** 90 天热力图（每天秒数，按日期升序；与 7 天柱状图独立加载） */
  @State heat: DayBar[] = [];
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
    // 汇总与明细并行取，互不依赖
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

    // 90 天热力图：独立加载（失败静默，热力图区块显示空格）
    const heatFrom: string = DateUtil.shiftDateKey(todayKey, -(HEAT_DAYS - 1));
    StatsService.loadRecentBars(heatFrom, todayKey).then((heat: DayBar[]) => {
      this.heat = heat;
    }).catch(() => {
      // 静默：热力图缺失时不阻塞整页
    });
  }

  build() {
    Column() {
      /**
       * 标题区：标题 + **日期副标题**（效果稿元素，"今天是哪天"的环境信息）。
       *
       * ⚠️ 标题与下面那条线**都带左右内边距**，而线是**通栏**的 ——
       * 所以它们不能共处一个带内边距的容器里：本 `build` 分了三段。
       */
      Column({ space: 5 }) {
        Text('统计')
          .fontSize(AppTheme.FONT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .letterSpacing(AppTheme.TRACK_TITLE)
          .width('100%')

        Text(this.todayCaption())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .letterSpacing(0.5)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
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
          Column() {
            this.buildLede()
            this.buildSectionTitle()
            this.buildRecentBars()
            this.buildHeatmap()
            this.buildLedger()
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .padding({
          left: AppTheme.PAGE_PADDING,
          right: AppTheme.PAGE_PADDING,
          top: AppTheme.GAP_L,
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

  /** 页头日期副标题："2025 年 6 月 12 日 · 星期四" */
  private todayCaption(): string {
    const d: Date = new Date();
    return `${d.getFullYear()} 年 ${d.getMonth() + 1} 月 ${d.getDate()} 日 · ${WEEKDAY_NAMES[d.getDay()]}`;
  }

  /**
   * 主数值 + 右侧两行眉标（效果稿的 lede 结构）。
   *
   * ⚠️ 数字与单位**交替渲染**："1时 24 分" = 数字(大) + 单位(小) + 数字(大) + 单位(小)，
   * 四个 `Text` 底部对齐 —— 效果稿里"时/分"小一号缀在数字后是排印惯例。
   * ⚠️ 右侧两行：「今 日」眉标 + 「比昨天多/少 X 分」（无昨日数据时只留眉标）。
   */
  @Builder
  buildLede() {
    Row() {
      // ── 左：1时 24 分 ──────────────────────────────
      Row({ space: 2 }) {
        if (this.ledeHours() >= 1) {
          Text(`${this.ledeHours()}`)
            .fontSize(54)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .fontFeature(AppFont.TABULAR)
            .fontFamily(AppFont.titleFamily())
          Text('时')
            .fontSize(17)
            .fontColor(AppColor.textSecondary)
            .fontFamily(AppFont.titleFamily())
            .margin({ left: 2, right: 4, bottom: 8 })
        }

        Text(`${this.ledeMinutes()}`)
          .fontSize(54)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
          .fontFamily(AppFont.titleFamily())

        Text('分')
          .fontSize(17)
          .fontColor(AppColor.textSecondary)
          .fontFamily(AppFont.titleFamily())
          .margin({ left: 2, bottom: 8 })
      }
      .alignItems(VerticalAlign.Bottom)
      .layoutWeight(1)

      // ── 右：今日 / 比昨天多 X 分 ────────────────────
      Column({ space: 5 }) {
        Text('今 日')
          .fontSize(11)
          .letterSpacing(2.6)
          .fontColor(AppColor.textHint)

        if (this.diffFromYesterdayText().length > 0) {
          Text(this.diffFromYesterdayText())
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.accent)
            .fontFeature(AppFont.TABULAR)
        }
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
  }

  /**
   * 段标题行：「最近七日 …… 共 6 时 08 分」。
   *
   * ⚠️ 30 天的展示职责已移交给下方的**热力图**（用户要求）：
   * 柱状图固定 7 天、按周几看节奏，热力图看 30 天的整体密度 —— 两图各司其职。
   */
  @Builder
  buildSectionTitle() {
    Row() {
      Text('最近七日')
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontWeight(FontWeight.Medium)
        // 段标题落衬线（探测到才有）—— 与全 app 的题字同一套语汇
        .fontFamily(AppFont.titleFamily())
        .letterSpacing(1)
        .fontColor(AppColor.textPrimary)
        // ⚠️ 标签吃掉剩余宽度，右侧合计才会被顶到右缘
        .layoutWeight(1)

      Text(`共 ${DateUtil.humanizeDuration(this.summary.weekSeconds)}`)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.textHint)
        .fontFeature(AppFont.TABULAR)
    }
    .width('100%')
    .margin({ top: AppTheme.GAP_L, bottom: AppTheme.GAP_M })
    .alignItems(VerticalAlign.Bottom)
  }

  // ── 主数值的拆解 ────────────────────────────────────

  private ledeHours(): number {
    return Math.floor(this.summary.todaySeconds / 3600);
  }

  private ledeMinutes(): number {
    return Math.floor((this.summary.todaySeconds % 3600) / 60);
  }

  /**
   * 与昨天的差值文案（"比昨天多 12 分" / "比昨天少 5 分"）。
   *
   * ⚠️ 昨天 = 柱状数组的倒数第二根（bars 按日期升序、最后一根是今天）。
   * 没有昨天数据（数组不足两根）时返回空串 —— 右侧只留「今 日」眉标，
   * 不显示"比昨天多 0 分"这种没信息的话。
   */
  private diffFromYesterdayText(): string {
    if (this.bars.length < 2) {
      return '';
    }
    const yesterday: DayBar = this.bars[this.bars.length - 2];
    const diff: number = this.summary.todaySeconds - yesterday.seconds;
    if (diff === 0) {
      return '与昨天持平';
    }
    const mins: number = Math.round(Math.abs(diff) / 60);
    return diff > 0 ? `比昨天多 ${mins} 分` : `比昨天少 ${mins} 分`;
  }

  // ══════════════════════════════════════════ 30 天热力图（本次新增）

  /**
   * 30 天热力图 —— GitHub contributions 的意象：每格一天，颜色深浅 = 读的时长。
   *
   * ## 为什么是热力图而不是 30 根柱子
   * 30 根柱挤在 390vp 宽里每根只有 ~10vp，柱顶数值根本放不下；
   * 而"30 天的阅读节奏"真正想看的是**密度**（哪些天读了、哪些天空着），
   * 方格 + 深浅恰好表达密度，不需要逐格数值。
   *
   * ## 排布
   * 按**周对齐**：第一行从当月第一格所在周的周日/周一开始……不——
   * 直接按"行 = 5 行 × 6 列"？不。对齐周（列 = 周一…周日）才是热力图：
   *  - 30 天 ≈ 4~5 行；每行 7 格固定对齐星期，行的首尾有空格 ——
   *    视觉上每行是"一周"，与柱状图的"周几"标签互相印证。
   *  - 行首的空位画 `paper-deep` 的空格（与 0 秒同色），保证每行 7 格等宽。
   *
   * ⚠️ 色阶只有**四档**，全部从既有令牌/低透明度叠出（不新增颜色）：
   *  - 0 → `divider`（空格，浅暖灰）
   *  - 低 → accent 15% / 中 → accent 45% / 高 → accent 100%
   *  - 分档阈值按 30 天内的最大值比例划（>0、>1/4、>1/2）——
   *    绝对阈值（如 30 分钟）在"整月只读一次"的用户眼里全是空格。
   */
  @Builder
  buildHeatmap() {
    Column() {
      // 区块标题：菱形落款 + 衬线题字（与书架/标注区块同一语汇）
      Row({ space: 8 }) {
        Column()
          .width(7)
          .height(7)
          .backgroundColor(AppColor.accent)
          .opacity(0.85)
          .rotate({ angle: 45 })

        Text('最近三个月')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontFamily(AppFont.titleFamily())
          .letterSpacing(1)
          .fontColor(AppColor.textPrimary)

        // 右端合计：30 天总量
        Text(this.heatTotalText())
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .fontFeature(AppFont.TABULAR)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: AppTheme.GAP_L, bottom: AppTheme.GAP_M })

      // 格阵：**横向时间轴**（左旧右今），列 = 周、行 = 周一~周日。
      // 90 天 ≈ 13 列，每列 layoutWeight(1) 等分铺满整行宽 —— "填满一大块"。
      Row({ space: HEAT_GAP }) {
        ForEach(this.heatColumns(), (col: Array<DayBar | null>, colIndex: number) => {
          Column({ space: HEAT_GAP }) {
            ForEach(col, (cell: DayBar | null, rowIndex: number) => {
              if (cell === null) {
                // 第一列顶部的对齐空位：占位不画色
                Column()
                  .width('100%')
                  .layoutWeight(1)
                  .opacity(0)
              } else {
                Column()
                  .width('100%')
                  .layoutWeight(1)
                  .borderRadius(2.5)
                  .backgroundColor(this.heatCellColor(cell.seconds))
                  /**
                   * 今天描边：热力格里没有"今天"文字位，
                   * 一道 1vp 的墨色描边是唯一可用的"今天在这里"标记。
                   */
                  .border({
                    width: cell.isToday ? 1 : 0,
                    color: AppColor.textPrimary
                  })
              }
            }, (cell: DayBar | null, rowIndex: number) => `heat_${colIndex}_${rowIndex}`)
          }
          .layoutWeight(1)
          .height(112)
        }, (col: Array<DayBar | null>, colIndex: number) => `heatcol_${colIndex}_${col.length}`)
      }
      .width('100%')

      // 图例：四档色样 + 少/多
      Row({ space: 5 }) {
        Text('少')
          .fontSize(10)
          .fontColor(AppColor.textHint)
        this.legendCell(0)
        this.legendCell(1)
        this.legendCell(2)
        this.legendCell(3)
        Text('多')
          .fontSize(10)
          .fontColor(AppColor.textHint)
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
  }

  /** 图例的一小格（与热力格同色同形，档位由 level 现算） */
  @Builder
  legendCell(level: number) {
    Column()
      .width(12)
      .height(12)
      .borderRadius(2.5)
      .backgroundColor(this.heatLevelColor(level))
  }

  /** 30 天合计文案（热力图标题右端） */
  private heatTotalText(): string {
    let total: number = 0;
    for (const d of this.heat) {
      total += d.seconds;
    }
    return `共 ${DateUtil.humanizeDuration(total)}`;
  }

  /** 秒数 → 色阶档位（0~3）；阈值按 30 天最大值的比例划 */
  private heatLevel(seconds: number): number {
    if (seconds <= 0) {
      return 0;
    }
    let max: number = 0;
    for (const d of this.heat) {
      if (d.seconds > max) {
        max = d.seconds;
      }
    }
    if (max <= 0) {
      return 0;
    }
    if (seconds > max / 2) {
      return 3;
    }
    if (seconds > max / 4) {
      return 2;
    }
    return 1;
  }

  /** 档位 → 颜色（0=空格，1~3 朱砂递增不透明度） */
  private heatLevelColor(level: number): ResourceColor {
    if (level === 0) {
      return AppColor.divider;
    }
    if (level === 1) {
      return 'rgba(168, 52, 42, 0.18)';
    }
    if (level === 2) {
      return 'rgba(168, 52, 42, 0.5)';
    }
    return AppColor.accent;
  }

  /** 今天的格子用什么色：正常走色阶（它往往就是最深的那格） */
  private heatCellColor(seconds: number): ResourceColor {
    return this.heatLevelColor(this.heatLevel(seconds));
  }

  /**
   * 把 90 天数组按星期对齐切成**列**（每列 7 格 = 一周，列首空位补 null）。
   *
   * ⚠️ 方向与 GitHub contributions 一致：**横向是时间**（左旧右今）、
   * 纵向是周一~周日。返回 `(DayBar | null)[][]`，外层是"周"（列），
   * 内层是"星期"（行）；null 表示"这格不属于窗口"（第一列的行首对齐用）。
   */
  private heatColumns(): Array<Array<DayBar | null>> {
    const columns: Array<Array<DayBar | null>> = [];
    if (this.heat.length === 0) {
      return columns;
    }
    // 第一天的星期几（0=周日）：决定第一列顶部补几个空位
    const first: DayBar = this.heat[0];
    const firstWeekday: number = this.weekdayIndexOf(first.label);
    let col: Array<DayBar | null> = [];
    for (let i = 0; i < firstWeekday; i++) {
      col.push(null);
    }
    for (const d of this.heat) {
      col.push(d);
      if (col.length === 7) {
        columns.push(col);
        col = [];
      }
    }
    // 最后一列不满 7 格也要推入：ForEach 对短列自然少画几格，
    // 剩余格留白（底部）—— 与 GitHub 的最后一列行为一致
    if (col.length > 0) {
      columns.push(col);
    }
    return columns;
  }

  /**
   * "MM-DD" → 星期下标（0=周日）。
   *
   * ⚠️ 与 `weekdayLabel` 同样的跨年近似：七天/三十天窗口跨年时
   * 旧年份的星期可能差一天，装饰信息可接受。
   */
  private weekdayIndexOf(dateKeyShort: string): number {
    const parts: string[] = dateKeyShort.split('-');
    if (parts.length !== 2) {
      return 0;
    }
    const year: number = new Date().getFullYear();
    const date: Date = new Date(year, Number.parseInt(parts[0], 10) - 1, Number.parseInt(parts[1], 10));
    if (Number.isNaN(date.getTime())) {
      return 0;
    }
    return date.getDay();
  }

  /**
   * 账目行：连续阅读 / 累计阅读 / 有记录天数。
   *
   * ⚠️ 「最近 7 天」一项已删（用户要求）：七天合计已经显示在
   * 段标题「最近七日」的右端，图表也把每天的量画了出来 ——
   * 再列一行是同一信息第三次出现。
   *
   * ⚠️ 三行**内联写死**，不抽带参 `@Builder` ——
   * 设计文档第 15/41 条：带参 `@Builder` 在同一处 `build()` 里被调多次时
   * 参数会串位；"结构相同、文字不同"的小单元必须逐个内联。
   *
   * ⚠️ 无卡片、无底色：账目行不需要容器，只有发丝线（效果稿如此）——
   * 主数值已经承担了版面重量，这里越轻越好。
   */
  @Builder
  buildLedger() {
    Column() {
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
   * 最近 7 天柱状图 —— **无卡片包裹**（效果稿：图直接长在纸面上）。
   *
   * 版面分两段：**绘图区**（水平网格线 + 基线 + 柱顶数值）与**标签行**。
   *
   * ⚠️ 为什么把标签拆到绘图区外面：基线必须落在绘图区下沿，
   * "柱子从这条线长起来"的语义才对。
   *
   * ⚠️ 两段用**同一个 `layoutWeight(1)` 等分方式**，柱与标签因此天然对齐。
   */
  @Builder
  buildRecentBars() {
    Column({ space: 6 }) {
      /**
       * 绘图区：网格线画在**柱子之下**（先画）——
       * 网格是背景参照，柱子是数据；反过来柱子会被线"切"。
       * 基线画在**柱子之后**（叠在柱子上），保证是连续的一条。
       */
      Stack({ alignContent: Alignment.Bottom }) {
        // ① 水平网格线
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
               * ⚠️ 今天那根柱子把圆点**挖在柱子内部**（柱顶 = 圆点，纸面色）：
               * 兄弟节点写法会把矮柱子顶高、柱底离开基线。
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
             * ⚠️ 柱列"数值在柱上方"的纵排：
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

      // 标签行：与绘图区同一套等分，因此与柱子逐列对齐。
      // ⚠️ x 轴显示**周几**（用户要求：七天刚好一周，按周算）——
      // 由日期键现算星期几，今天仍显示朱色「今天」。
      Row({ space: BAR_GAP }) {
        ForEach(this.bars, (bar: DayBar) => {
          Text(bar.isToday ? '今天' : this.weekdayLabel(bar.label))
            .fontSize(10)
            .fontColor(bar.isToday ? AppColor.accent : AppColor.textHint)
            .fontWeight(bar.isToday ? FontWeight.Medium : FontWeight.Normal)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
        }, (bar: DayBar) => `label_${bar.label}`)
      }
      .width('100%')
    }
    .width('100%')
  }

  /**
   * 日期键（"MM-DD"）→ 周几标签（"周五"）。
   *
   * ⚠️ 键只有月和日，补上当前年份拼回完整日期再取 `getDay()`。
   * 跨年的一周（12-31 → 01-01）里旧年份会算错星期 —— 七天窗口
   * 最多跨一天，误差仅出现在 12 月最后几天，且只是"周几"的装饰
   * 信息，可接受；不做跨年特判是为了不把简单的事做复杂。
   */
  private weekdayLabel(dateKeyShort: string): string {
    const parts: string[] = dateKeyShort.split('-');
    if (parts.length !== 2) {
      return dateKeyShort;
    }
    const year: number = new Date().getFullYear();
    const date: Date = new Date(year, Number.parseInt(parts[0], 10) - 1, Number.parseInt(parts[1], 10));
    if (Number.isNaN(date.getTime())) {
      return dateKeyShort;
    }
    return WEEKDAY_NAMES[date.getDay()];
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
   *
   * ⚠️ **必须给满格柱留出数值区**（真机实测的溢出）：
   * 柱列 = 柱顶数值(约 14vp 含间距) + 柱体，而列高只有 `PLOT_HEIGHT`。
   * 最高一天的柱高若等于 `PLOT_HEIGHT`，"数值 + 柱"就超出容器 ——
   * `justifyContent(End)` 会把超出的部分从**顶部**裁，柱底被顶到基线以下，
   * 盖住下方的标签（正是"今天的红柱压住『今天』二字"的原因）。
   * 满格高度因此封顶为 `PLOT_HEIGHT - 22`（数值 + 间距的预留）。
   */
  private barHeight(seconds: number): number {
    // 数值文本(9.5vp 行高) + margin(4) 的预留，另加安全余量
    const maxBarHeight: number = PLOT_HEIGHT - 22;
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
    return Math.min(maxBarHeight, Math.max(6, Math.round(seconds / max * maxBarHeight)));
  }

  // ══════════════════════════════════════════════ 书架与标注（本次新增区块）

  /** 账目行的行内样式复用太散，抽成一个带参 @Builder **只收纯文本**（无行为） */
  @Builder
  ledgerRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(AppColor.textSecondary)
        .layoutWeight(1)
      Text(value)
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .fontFeature(AppFont.TABULAR)
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Bottom)
    .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })
  }

  // ⚠️ 「书架」「标注」两个区块已删除（用户要求）：
  // ShelfOverview / AnnotationCounts 及其加载逻辑一并移除（StatsService 中的
  // loadShelfOverview / loadAnnotationCounts 保留——以后要用随时能接回来）。
}
