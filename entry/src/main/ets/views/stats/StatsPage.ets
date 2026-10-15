import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { StatsService, DayBar } from '../../data/service/StatsService';
import { StatsSummary } from '../../model/DailyStats';
import { DateUtil } from '../../common/utils/DateUtil';
import { Logger } from '../../common/utils/Logger';

/** 折线/柱状图展示最近几天 */
const RECENT_DAYS: number = 7;
/** 柱子的最大高度（vp） */
const BAR_MAX_HEIGHT: number = 96;

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
    Column({ space: AppTheme.GAP_M }) {
      Text('统计')
        .fontSize(AppTheme.FONT_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .width('100%')

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
            this.buildSummaryCards()
            this.buildRecentBars()
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .padding(AppTheme.PAGE_PADDING)
    .backgroundColor(AppColor.bgPage)
  }

  /**
   * 顶部 2×2 汇总卡片：今天 / 本周 / 连续 / 累计。
   *
   * ⚠️ 四张卡片**内联写死**，不抽带参 `@Builder` ——
   * 设计文档第 15/41 条：带参 `@Builder` 在同一处 `build()` 里被调多次时
   * 参数会串位；"结构相同、文字不同"的小单元必须逐个内联。
   */
  @Builder
  buildSummaryCards() {
    Row({ space: AppTheme.GAP_M }) {
      Column({ space: AppTheme.GAP_S }) {
        Text('今天').fontSize(AppTheme.FONT_CAPTION).fontColor(AppColor.textHint)
        Text(DateUtil.humanizeDuration(this.summary.todaySeconds))
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding(AppTheme.GAP_M)
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)

      Column({ space: AppTheme.GAP_S }) {
        Text('最近 7 天').fontSize(AppTheme.FONT_CAPTION).fontColor(AppColor.textHint)
        Text(DateUtil.humanizeDuration(this.summary.weekSeconds))
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding(AppTheme.GAP_M)
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)
    }
    .width('100%')

    Row({ space: AppTheme.GAP_M }) {
      Column({ space: AppTheme.GAP_S }) {
        Text('连续阅读').fontSize(AppTheme.FONT_CAPTION).fontColor(AppColor.textHint)
        Text(`${this.summary.continuousDays} 天`)
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding(AppTheme.GAP_M)
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)

      Column({ space: AppTheme.GAP_S }) {
        Text('累计阅读').fontSize(AppTheme.FONT_CAPTION).fontColor(AppColor.textHint)
        Text(DateUtil.humanizeDuration(this.summary.totalSeconds))
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding(AppTheme.GAP_M)
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)
    }
    .width('100%')
  }

  /** 最近 7 天柱状图：高度按最大值归一，0 秒画一根最矮的底线 */
  @Builder
  buildRecentBars() {
    Column({ space: AppTheme.GAP_M }) {
      Text('最近 7 天')
        .fontSize(AppTheme.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      Row({ space: AppTheme.GAP_S }) {
        ForEach(this.bars, (bar: DayBar) => {
          Column({ space: 4 }) {
            Blank()
            Column()
              .width(18)
              .height(this.barHeight(bar.seconds))
              .borderRadius(4)
              .backgroundColor(bar.isToday ? AppColor.accent : AppColor.primary)
              .alignSelf(ItemAlign.End)
            Text(bar.label)
              .fontSize(10)
              .fontColor(bar.isToday ? AppColor.accent : AppColor.textHint)
              .maxLines(1)
          }
          .layoutWeight(1)
          .height(BAR_MAX_HEIGHT + 24)
          .justifyContent(FlexAlign.End)
        }, (bar: DayBar) => bar.label)
      }
      .width('100%')

      Text(this.barsHint())
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.textHint)
        .width('100%')
    }
    .width('100%')
    .padding(AppTheme.GAP_M)
    .backgroundColor(AppColor.bgCard)
    .borderRadius(AppTheme.CARD_RADIUS)
  }

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
    return Math.max(6, Math.round(seconds / max * BAR_MAX_HEIGHT));
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
