import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { StatsService, DayBar } from '../../data/service/StatsService';
import { StatsSummary } from '../../model/DailyStats';
import { ReadingRecordSummary } from '../../model/ReadingRecord';
import { DateUtil } from '../../common/utils/DateUtil';
import { Logger } from '../../common/utils/Logger';
import { IconChevron } from '../common/Marks';
import { ReadingRecordDialog } from './ReadingRecordDialog';

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
 * 阅读记录区块里三格账目的竖向分隔线高度（vp）。
 *
 * ⚠️ 竖线要有确定高度：`Row` 的交叉轴默认居中，
 * 不写高度会被压成 0、完全看不见。
 */
const RECORD_RULE_H: number = 30;

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
 * ⚠️ 本图是 `build()` 里实际的渲染顺序，改版面时**必须同步改它**：
 * 早先这里还画着「◆ 书架」「◆ 标注」两个区块，而它们已被用户要求删除
 * （代码在文件末尾，两个组件与加载逻辑一并移除）—— 图与代码不一致的注释
 * 比没有注释更糟，它会让人以为"漏实现了"。
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
 * 总阅读时长              42 时 18 分   ← 单行账目（无段标题，紧接热力图）
 * ──────────────────────────────
 *   6 本   │   63 天   │   17 天     ← 三格账目，竖线分隔
 * 阅读书目     阅读天数     连续阅读
 * ──────────────────────────────
 * 各书时长        6 本 · 3 时 46 分 ›  ← 可点入口 → ReadingRecordDialog
 * ```
 *
 * ⚠️ **原「账目行」区块已删除**：它的三项（连续阅读 / 累计阅读 / 有记录的天数）
 * 被上面的阅读记录块逐项取代（单行「总阅读时长」+ 三格账目），
 * 并存会让同一页出现两遍相同数字。详见 `buildReadingRecord` 之前的说明。
 */
@Component
export struct StatsPage {
  @State summary: StatsSummary = new StatsSummary();
  @State bars: DayBar[] = [];
  /** 90 天热力图（每天秒数，按日期升序；与 7 天柱状图独立加载） */
  @State heat: DayBar[] = [];
  /**
   * 阅读记录区块的数据（每本书的累计时长 + 书数 / 天数 / 连续天数）。
   *
   * ⚠️ 与 `summary` 是**两份数据**，尽管字段有重叠：
   * `summary` 来自 `loadSummary()`（统计页既有通道），本项来自
   * `loadReadingRecord()`（阅读记录通道）。两者都读同一张表的
   * `book_id = 0` 行，但**本区块不读 `summary`** —— 一个区块的显示
   * 只依赖一个数据源，将来其中一条通道改了字段，不会出现
   * "这块跟着变、那块没变"的半更新状态。
   */
  @State record: ReadingRecordSummary = new ReadingRecordSummary();
  /**
   * 「各书时长」弹窗是否可见。
   *
   * ⚠️ 弹窗挂在**最外层 `Stack`** 上（与 `BookShelfPage` 的弹窗同一套做法）：
   * 放在 `Scroll` 里会参与布局、把内容挤短，而 `Stack` 是层叠语义。
   * 因此本页的根节点需要从 `Column` 改成 `Stack`。
   */
  @State private recordDialogVisible: boolean = false;
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

    /**
     * 阅读记录区块：独立加载。
     *
     * ⚠️ 与前两段**分开、各自 catch**：本区块失败时其余统计照常显示，
     * 不能因为一张列表查不出来就把整页变成错误态（那三段已经加载好了）。
     * 失败时留空对象 → `bookCount === 0` → 整块不渲染，是**优雅降级**。
     */
    StatsService.loadReadingRecord().then((r: ReadingRecordSummary) => {
      this.record = r;
    }).catch((e: Object) => {
      Logger.error('StatsPage', `阅读记录加载失败: ${Logger.errText(e)}`);
    });
  }

  build() {
    /**
     * ⚠️ 根节点是 `Stack` 而不是 `Column` —— 为「各书时长」弹窗服务。
     *
     * 弹窗是全屏浮层，必须能盖住整页（层叠语义）。若把它作为 `Column`
     * 的最后一个子节点，它会参与纵向布局、把上面的内容挤短
     * （弹窗自己 `height('100%')`，会把父容器撑爆）——
     * 与 `BookShelfPage` 用 `Stack` 装弹窗是同一套做法。
     */
    Stack() {
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
              /**
               * ⚠️ 原 `buildLedger()`（连续阅读 / 累计阅读 / 有记录的天数）
               * **已删除**，因为下面那块阅读记录把它**逐项覆盖**了：
               *   连续阅读     → 阅读记录的「连续阅读」格（同值）
               *   累计阅读     → 阅读记录的「总阅读时长」（同值）
               *   有记录的天数 → 阅读记录的「阅读天数」格（同值）
               * 两块并存会让同一页出现两遍相同数字（"累计阅读 42 时 18 分"
               * 与"总阅读时长 42 时 18 分"），那是明确的缺陷而不是冗余保险。
               * 判据：**后一块完整包含前一块时，删掉前一块。**
               *
               * ⚠️ 阅读记录块**只在有数据时渲染**（见 `buildReadingRecord`）：
               * 从未读过书时，一块全 0 的表格是噪声。
               * 放在 `if` 里而不是让 builder 内部 return ——
               * `@Builder` 不能提前 return，条件必须由调用处表达。
               */
              if (this.record.bookCount > 0) {
                this.buildReadingRecord()
              }
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

      /**
       * 「各书时长」弹窗 —— 挂在**外层 Stack** 上（层叠语义，见 `build()` 顶部说明）。
       *
       * ⚠️ 数据条件也判一次：`recordDialogVisible` 是独立状态，
       * 若数据重新加载后变空（例如刚清空了所有数据），
       * 不该留一个空弹窗浮在页面上。
       */
      if (this.recordDialogVisible && this.record.bookCount > 0) {
        ReadingRecordDialog({
          books: this.record.books,
          totalSeconds: this.record.totalSeconds,
          onClose: () => {
            this.recordDialogVisible = false;
          }
        })
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
   * ⚠️ 原「账目行」区块（连续阅读 / 累计阅读 / 有记录的天数）**已删除**。
   *
   * 它被下方阅读记录块的**三个对应项**取代：
   *   连续阅读     → 三格账目的「连续阅读」
   *   累计阅读     → 单行账目「总阅读时长」（`DateUtil.humanizeDuration`，同文案）
   *   有记录的天数 → 三格账目的「阅读天数」
   *
   * 两块并存会让同一页出现两遍完全相同的数字，那是缺陷不是冗余保险。
   * 判据：**后一块完整包含前一块时，删掉前一块。**
   *
   * 阅读记录块用的是 `record`（`loadReadingRecord` 通道）而不是
   * 这里的 `summary`（`loadSummary` 通道）—— 一个区块只依赖一个数据源，
   * 将来其中一条通道改了字段，不会出现"这块跟着变、那块没变"的半更新。
   */

  /**
   * 「阅读记录」区块 —— 本页**最末一块**（用户要求把整个页面搬到这里）。
   *
   * ⚠️ **不是入口行，是内容本身**：原先 `pages/ReadingRecordPage` 是一整页，
   * 现在它的版面（总阅读时长 / 三格账目 / 各书时长列表）落在本页下方，
   * 由本页的 `Scroll` 统一滚动。因此：
   *  - 不再需要 `RouteName.READING_RECORD_PAGE` 跳转；
   *  - 不再需要那个页面的标题栏与返回按钮（本页已有自己的标题）；
   *  - 数据由本页 `reload()` 一起加载（见那边的 `loadReadingRecord`）。
   *
   * ⚠️ **本块没有自己的段标题**（用户要求删掉「阅读记录」四个字）：
   * 它紧跟在热力图之后，位置本身已经表达了"新的一段"；
   * 块内「各书时长」才是唯一的段标题。
   *
   * ⚠️ 与上面各区块的分工：
   * 上面看"时间**分布**"（七日柱状图、90 天热力图），
   * 本块看"时间**去向**"（每本书各读了多久、一共读了几本）。
   *
   * ⚠️ **数据为空时整块不渲染**（`bookCount === 0`）：
   * 从未读过书时，一块全 0 的表格是噪声 ——
   * 上面的柱状图与热力图已经是空的了，再来一块全 0 的只会让人觉得
   * "是不是坏了"。判据：**空数据不画零值表。**
   * 注意这与被删掉的账目行不同：那三行曾是**始终有意义**的累计值，
   * 而本块主体是一张列表，没有列表就没有内容。
   */
  /**
   * 「阅读总览」卡 —— 本页**最末一块**（用户要求把整个页面搬到这里）。
   *
   * ## 结构（与导入确认页的「分章预览」卡同一套：**表头在卡内**）
   * ```
   * ┌───────────────────────────────────┐
   * │ 阅读总览                            │  ← 表头（衬线），下方一条发丝线
   * │ ───────────────────────────────── │
   * │ 总阅读时长              3 小时 46 分 │  ← 账目行
   * │ ───────────────────────────────── │
   * │  23本   │   6天    │   6天          │  ← 三格账目（竖线分隔）
   * │ 阅读书目   阅读天数    连续阅读       │
   * │ ───────────────────────────────── │
   * │ 各书时长        6 本 · 3 时 46 分 › │  ← 可点入口 → 弹窗
   * └───────────────────────────────────┘
   * ```
   *
   * ⚠️ **三块收进一张卡**（用户要求）：早先是三条裸的行（无卡、只有发丝线），
   * 在纸面上散着；收进卡后与上面的信息卡/预览卡是同一个"表"的量感。
   * 行间分隔仍用发丝线，卡片只提供**一条外边界** —— 与书架列表卡同一纪律。
   *
   * ⚠️ 不是入口行，是内容本身：原 `pages/ReadingRecordPage` 的版面落在本页，
   * 数据由本页 `reload()` 一起加载（`loadReadingRecord` 通道）。
   *
   * ⚠️ **数据为空时整块不渲染**（`bookCount === 0`）：
   * 从未读过书时，一块全 0 的表格是噪声 ——
   * 上面的柱状图与热力图已经是空的了，再来一块全 0 的只会让人觉得
   * "是不是坏了"。判据：**空数据不画零值表。**
   */
  @Builder
  buildReadingRecord() {
    Column() {
      // ── 表头（卡内）：「阅读总览」，下方一条发丝线 ──────────
      Row() {
        Text('阅读总览')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontFamily(AppFont.titleFamily())
          .letterSpacing(1)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 15, bottom: 14, left: 18, right: 18 })

      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)

      /**
       * ① 总阅读时长 —— 账目行（左标签 + 右数值）。
       *
       * ⚠️ 值走 `DateUtil.humanizeDuration`，与统计页其他时长文案**同源**
       * （"3 小时 46 分"）。
       */
      Row() {
        Text('总阅读时长')
          .fontSize(13)
          .fontColor(AppColor.textHint)
          .letterSpacing(0.5)
          .layoutWeight(1)

        Text(DateUtil.humanizeDuration(this.record.totalSeconds))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding({ top: 16, bottom: 16, left: 18, right: 18 })
      .alignItems(VerticalAlign.Bottom)

      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)

      /**
       * ② 三格账目：阅读书目 / 阅读天数 / 连续阅读。
       *
       * ⚠️ 三格**内联写死**，不用带参 `@Builder` ——
       * 设计文档第 15/41 条：带参 `@Builder` 在同一处 `build()` 里
       * 被调多次时**参数会串位**（本项目实测踩过）。这里恰好调三次。
       *
       * ⚠️ 竖线必须有**确定高度**：`Row` 交叉轴默认居中，
       * 不写高度会被压成 0、完全看不见。
       */
      Row() {
        Column({ space: 4 }) {
          Row({ space: 2 }) {
            Text(`${this.record.bookCount}`)
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
              .fontFeature(AppFont.TABULAR)
              .fontFamily(AppFont.titleFamily())
            Text('本')
              .fontSize(12)
              .fontColor(AppColor.textSecondary)
              .fontFamily(AppFont.titleFamily())
              .margin({ bottom: 4 })
          }
          .alignItems(VerticalAlign.Bottom)

          Text('阅读书目')
            .fontSize(11)
            .fontColor(AppColor.textHint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Row()
          .width(AppTheme.HAIRLINE)
          .height(RECORD_RULE_H)
          .backgroundColor(AppColor.divider)

        Column({ space: 4 }) {
          Row({ space: 2 }) {
            Text(`${this.record.readingDays}`)
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
              .fontFeature(AppFont.TABULAR)
              .fontFamily(AppFont.titleFamily())
            Text('天')
              .fontSize(12)
              .fontColor(AppColor.textSecondary)
              .fontFamily(AppFont.titleFamily())
              .margin({ bottom: 4 })
          }
          .alignItems(VerticalAlign.Bottom)

          Text('阅读天数')
            .fontSize(11)
            .fontColor(AppColor.textHint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Row()
          .width(AppTheme.HAIRLINE)
          .height(RECORD_RULE_H)
          .backgroundColor(AppColor.divider)

        Column({ space: 4 }) {
          Row({ space: 2 }) {
            Text(`${this.record.continuousDays}`)
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
              .fontFeature(AppFont.TABULAR)
              .fontFamily(AppFont.titleFamily())
            Text('天')
              .fontSize(12)
              .fontColor(AppColor.textSecondary)
              .fontFamily(AppFont.titleFamily())
              .margin({ bottom: 4 })
          }
          .alignItems(VerticalAlign.Bottom)

          Text('连续阅读')
            .fontSize(11)
            .fontColor(AppColor.textHint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .padding({ top: 16, bottom: 16 })
      .alignItems(VerticalAlign.Center)

      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)

      /**
       * ③ 各书时长 —— **一行可点的入口**（点开弹窗看列表）。
       *
       * ⚠️ 形态与本卡其他行**刻意不同**，这是有意的层级区分：
       * 账目行是**只读数据**，无箭头、点了没反应；
       * 本行是**可点入口**，右侧给 `IconChevron` 折角 ——
       * 与「我的」页那几行同一套"能点"的记号。
       * 判据：**同一页里"数据"与"入口"必须长得不一样。**
       *
       * ⚠️ 右端是「N 本 · 总时长」：让用户在**点开之前**就知道
       * 里面有东西、有多少。
       */
      Row() {
        Text('各书时长')
          .fontSize(14)
          .fontColor(AppColor.textPrimary)
          .letterSpacing(0.5)
          .layoutWeight(1)

        Text(`${this.record.bookCount} 本 · ${DateUtil.humanizeDuration(this.record.totalSeconds)}`)
          .fontSize(12)
          .fontColor(AppColor.textHint)
          .fontFeature(AppFont.TABULAR)
          .margin({ right: 6 })

        IconChevron()
      }
      .width('100%')
      .padding({ top: 16, bottom: 16, left: 18, right: 18 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.recordDialogVisible = true;
      })
    }
    .width('100%')
    .margin({ top: AppTheme.GAP_L })
    .borderRadius(AppTheme.CARD_RADIUS)
    .backgroundColor(AppColor.bgCard)
    .clip(true)
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

  // ══════════════════════════════════════════════ 阅读记录（本次从独立页搬入）

  /**
   * ⚠️ 原来本页还有 `rankText` / `bookTitleOf` / `compactDuration` /
   * `recordRailPercent` 四个方法，以及 `buildRecordRail` 这个 @Builder ——
   * 它们**全部随各书时长列表一起搬进了 `ReadingRecordDialog`**。
   * 列表搬进弹窗后本页不再渲染书单，留着这些方法就是死代码。
   *
   * ⚠️ 原 `recordHours()` / `recordMinutes()` 也**已删除**：
   * 「总阅读时长」改回单行账目后，时长整串交给
   * `DateUtil.humanizeDuration` 渲染，不再需要自己拆时/分两个数字。
   */
}
