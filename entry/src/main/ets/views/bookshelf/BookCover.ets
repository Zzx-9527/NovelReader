import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { FileUtil } from '../../common/utils/FileUtil';

/**
 * 书籍占位封面 —— **全项目唯一的封面渲染入口**。
 *
 * TXT 没有封面，所以用"书名首字 + 中性底"占位。这个做法原本重复写在
 * `BookGridItem` / `BookListItem` / `ContinueReadingCard` 三处，
 * 本次重构把它抽成一个组件，理由是本次要往封面上加四样东西
 * （书脊、题花线、右上角百分比、底部进度发丝）——
 * 三处各写一遍等于三份会各自漂移的实现（设计文档第 28 条）。
 *
 * ## 四层结构（自上而下、自左而右）
 * ```
 * ┌─────────────────────────┐
 * │▍                        │  ▍ = 书脊：3vp 宽、accent、55% 不透明度
 * │▍        江              │  首字：27vp 加粗、cover_text、字距 1
 * │▍       ────             │  题花线：18×1vp、cover_text 45%
 * │▍                  62%   │  右上角百分比（仅非紧凑模式）
 * │▍████████░░░░░░░░░░░░░░░░│  底部进度发丝：2vp，轨道 22% + accent 填充
 * └─────────────────────────┘
 * ```
 *
 * ⚠️ **配色一个值都没改**：底色仍是 `cover_bg`、首字仍是 `cover_text`。
 * 唯一用到点缀色的是那条 3vp 书脊与 2vp 进度填充 —— 都是小面积，
 * 符合 `AppColor.accent` 注释里那条"大色块一律中性，颜色只留给小面积"的纪律。
 *
 * ⚠️ 本组件**不决定自己的尺寸**：它一律 `width('100%').height('100%')`，
 * 由外层容器给尺寸。这样网格（`aspectRatio(3/4)`）、列表（48×64）、
 * 继续阅读卡（56×76）三种尺寸共用同一份实现，不需要为尺寸传参。
 */
@Component
export struct BookCover {
  /** 居中的首字（1~2 个字符，由调用方从书名截取） */
  @Prop label: string = '书';
  /** 阅读进度 0~1；0 表示未开始读，此时**不画**轨道与百分比 */
  @Prop percent: number = 0;
  /**
   * 紧凑模式（列表 48×64 / 继续阅读卡上的小封面）。
   *
   * ⚠️ 它改的是**排版密度**，不是尺寸：首字 27→20、字距 1→0、
   * 不画题花线、不画右上角百分比。列表行的百分比由右侧进度行承担，
   * 封面再显示一次是重复信息（而这正是设计文档禁止的"两处显示同一信息"）。
   */
  @Prop compact: boolean = false;
  /**
   * 首字字号的**显式覆盖**；0 表示用默认（网格 27 / 紧凑 20）。
   *
   * ⚠️ 只有分组封面（`GroupCover`）用它：格子只有约 50×70，
   * 默认的 20~27vp 大字会把格子撑满（真机实测"两个大字顶满格子"），
   * 14vp 才是格子里的合适量级。书架上的正常封面**不要传**这个参数 ——
   * 字号口径仍由 compact 推导，避免出现第三套默认值。
   */
  @Prop glyphSize: number = 0;

  /** 首字实际字号：显式覆盖优先，否则按 compact 推导 */
  private glyphFontSize(): number {
    if (this.glyphSize > 0) {
      return this.glyphSize;
    }
    return this.compact ? 20 : 27;
  }

  /** 进度百分比文本；0% 时返回空串，调用方不渲染 */
  private percentText(): string {
    return this.percent > 0 ? FileUtil.humanPercent(this.percent) : '';
  }

  /**
   * 进度填充宽度。
   *
   * ⚠️ 返回**字符串百分比**而不是算像素：封面宽度在三种尺寸下都不同，
   * 而算像素需要知道宽度 —— 组件拿不到（它不决定自己的尺寸，见类注释）。
   * 用百分比让布局引擎去算，三种尺寸自动正确。
   */
  private fillWidth(): string {
    const clamped: number = this.percent < 0 ? 0 : (this.percent > 1 ? 1 : this.percent);
    return `${(clamped * 100).toFixed(1)}%`;
  }

  build() {
    Column() {
      /**
       * 上半：书脊 + 内容。
       *
       * ⚠️ 用 `Row`（书脊 + 内容两列）而**不是**把书脊做成 `Stack` 里
       * 一个 `position` 定位的浮层：`Row` 让"内容区 = 封面宽 − 3vp"由布局
       * 自动算出，首字因此真正居中于**可见的书面**。
       */
      Row() {
        // ① 书脊：低不透明度的点缀色，读作"书的厚度"
        Column()
          .width(AppTheme.COVER_SPINE_W)
          .height('100%')
          .backgroundColor(AppColor.accent)
          .opacity(AppTheme.COVER_SPINE_ALPHA)

        /**
         * ② 书面的内容层。
         *
         * ⚠️ `Stack({ alignContent: Alignment.TopEnd })` 是刻意选的：
         * 内层的 `Column` 铺满 100%×100% 并**自己**居中首字，
         * 所以 `alignContent` 对它不起作用；真正受它影响的只有右上角
         * 那个百分比文本 —— 用 `TopEnd` 一句话就把它钉在右上角。
         */
        Stack({ alignContent: Alignment.TopEnd }) {
          Column({ space: this.compact ? 0 : 5 }) {
            Text(this.label)
              .fontSize(this.glyphFontSize())
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.coverText)
              // 衬线（探测到才有）+ 字距 —— "书卷气"的两个来源，见 AppFont 说明
              .fontFamily(AppFont.titleFamily())
              .letterSpacing(this.compact ? 0 : AppTheme.TRACK_COVER)

            // ③ 题花线：收住首字的视觉重心，让它不再"浮在色块中央"
            if (!this.compact) {
              Row()
                .width(AppTheme.COVER_RULE_W)
                .height(AppTheme.HAIRLINE)
                .backgroundColor(AppColor.coverText)
                .opacity(AppTheme.COVER_RULE_ALPHA)
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)

          // ④ 右上角百分比：无底色、9vp、安静 —— 取代原来的黑色角标
          if (!this.compact && this.percent > 0) {
            Text(this.percentText())
              .fontSize(9)
              .fontColor(AppColor.coverText)
              .fontFeature(AppFont.TABULAR)
              .margin({ top: 5, right: 7 })
          }
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      // ⚠️ 吃掉"封面高 − 进度发丝高"的全部余量：用 layoutWeight 而不是
      // height('100%')，否则下面那条 2vp 的线会把封面顶高 2vp，
      // 网格里每一格都比 aspectRatio 多出 2vp，累积成整列错位。
      .layoutWeight(1)

      /**
       * 进度发丝：轨道（22% cover_text）+ 填充（accent）。
       *
       * ⚠️ 只在**有进度**时渲染。未读的书不画空轨道 ——
       * 一屏 9 格里 5 本没读过，那 5 条空线会变成噪声，
       * 而"没读过"本身不需要视觉表达。
       */
      if (this.percent > 0) {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(AppTheme.RAIL_H)
            .backgroundColor(AppColor.coverText)
            .opacity(AppTheme.COVER_TRACK_ALPHA)

          Row()
            .width(this.fillWidth())
            .height(AppTheme.RAIL_H)
            .backgroundColor(AppColor.accent)
        }
        .width('100%')
        .height(AppTheme.RAIL_H)
      }
    }
    .width('100%')
    .height('100%')
  }
}
