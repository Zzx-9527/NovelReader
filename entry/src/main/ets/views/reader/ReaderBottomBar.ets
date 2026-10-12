import { AppTheme, ReaderTheme } from '../../common/theme/AppTheme';

/**
 * 阅读页底部进度栏。
 *
 * 版面（从上到下）：
 * ```
 * 章节名 ............................... 3/12  42.3%   ← 左=在哪一章，右=全书进度
 * [上一章] ============进度条============ [下一章]
 * ```
 * 章节名与百分比必须在**这里常驻**：顶栏的章节名只在菜单弹出时可见，
 * 而"读到第几章了、全书读了百分之多少"是阅读中随时想知道的。
 *
 * ⚠️ 几个展示值必须用 `@Prop`：普通成员只在组件**创建时**取一次快照，
 * 父组件后续的状态变化不会同步进来 —— 表现为"拖动进度条后数字又弹回去"。
 *
 * 拖动过程中只更新本地状态（draggingPercent），松手才真正跳章（SliderChangeMode.End），
 * 避免拖动时反复触发重排。
 */
@Component
export struct ReaderBottomBar {
  theme: ReaderTheme = new ReaderTheme();
  /** 正文字号：栏内文字统一比它小一号（`AppTheme.SIZE_STEP`） */
  @Prop baseFontSize: number = 18;
  /** 0~1 */
  @Prop percent: number = 0;
  @Prop chapterTitle: string = '';
  /** 页码文案，如 "3/12"；scroll 模式传空串 */
  @Prop pageText: string = '';
  /** 是否还有上一章 / 下一章：首末章时把按钮置灰 */
  @Prop hasPrev: boolean = false;
  @Prop hasNext: boolean = false;
  onJump?: (percent: number) => void;
  onPrevChapter?: () => void;
  onNextChapter?: () => void;
  onOpenSettings?: () => void;

  @State private draggingPercent: number = -1;

  private displayPercent(): number {
    return this.draggingPercent < 0 ? this.percent : this.draggingPercent;
  }

  /** 栏内文字字号：比正文小一号 */
  private fontSize(): number {
    return Math.max(10, this.baseFontSize - AppTheme.SIZE_STEP);
  }

  build() {
    Column({ space: 6 }) {
      // 左：读到哪一章；右：整本书的进度
      Row({ space: 8 }) {
        Text(this.chapterTitle)
          .fontSize(this.fontSize())
          .fontColor(this.theme.secondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.pageText.length > 0) {
          Text(this.pageText)
            .fontSize(this.fontSize())
            .fontColor(this.theme.secondary)
        }
        Text(`${(this.displayPercent() * 100).toFixed(1)}%`)
          .fontSize(this.fontSize())
          .fontColor(this.theme.secondary)

        // 设置入口放在这一行，而不是第二行进度条两端：
        // 那两个位置已经被上一章/下一章占了（相邻章切换是高频动作），
        // 再挤进去会让进度条短得没法拖。
        Text('设置')
          .fontSize(this.fontSize())
          .fontColor(this.theme.text)
          .padding({ left: 8, top: 2, bottom: 2 })
          .onClick(() => {
            if (this.onOpenSettings !== undefined) {
              this.onOpenSettings();
            }
          })
      }
      .width('100%')

      // 上一章 / 进度条 / 下一章 同一行：相邻章切换是最常用的动作，
      // 放在进度条两端，拇指点左右两侧都能够到（放下面一行就得上下移拇指）。
      Row() {
        // ⚠️ 两个按钮内联写死，不抽带参 @Builder 复用：
        // 设计文档第 15 条 —— 同一个 build() 里把带参 @Builder 调多次，参数会串位。
        Text('上一章')
          .fontSize(this.fontSize())
          .fontColor(this.hasPrev ? this.theme.text : this.theme.secondary)
          .opacity(this.hasPrev ? 1 : 0.4)
          .padding({ top: 6, bottom: 6, left: 2, right: 10 })
          .onClick(() => {
            // 置灰只是体验层，规则层要自己判断：见设计文档第 29 条
            if (this.hasPrev && this.onPrevChapter !== undefined) {
              this.onPrevChapter();
            }
          })

        Slider({
          value: this.displayPercent() * 100,
          min: 0,
          max: 100,
          step: 1
        })
          .selectedColor(this.theme.text)
          .trackColor(this.theme.secondary)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              // 松手才跳章
              this.draggingPercent = -1;
              if (this.onJump !== undefined) {
                this.onJump(value / 100);
              }
            } else {
              // 拖动中只改显示
              this.draggingPercent = value / 100;
            }
          })

        Text('下一章')
          .fontSize(this.fontSize())
          .fontColor(this.hasNext ? this.theme.text : this.theme.secondary)
          .opacity(this.hasNext ? 1 : 0.4)
          .padding({ top: 6, bottom: 6, left: 10, right: 2 })
          .onClick(() => {
            if (this.hasNext && this.onNextChapter !== undefined) {
              this.onNextChapter();
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    .backgroundColor(this.theme.barBg)
  }
}
