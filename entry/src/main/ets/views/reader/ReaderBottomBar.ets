import { ReaderTheme } from '../../common/theme/AppTheme';

/**
 * 阅读页底部进度栏。
 *
 * 拖动过程中只更新 UI（onChange），松手才真正跳章（onChange 结束用 onSubmit）——
 * 避免拖动时反复触发重排。
 */
@Component
export struct ReaderBottomBar {
  theme: ReaderTheme = new ReaderTheme();
  /** 0~1 */
  percent: number = 0;
  chapterTitle: string = '';
  /** 页码文案，如 "3/12"；scroll 模式传空串 */
  pageText: string = '';
  onJump?: (percent: number) => void;

  @State private draggingPercent: number = -1;

  private displayPercent(): number {
    return this.draggingPercent < 0 ? this.percent : this.draggingPercent;
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.chapterTitle)
          .fontSize(12)
          .fontColor(this.theme.secondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.pageText.length > 0) {
          Text(this.pageText)
            .fontSize(12)
            .fontColor(this.theme.secondary)
        }
        Text(`${(this.displayPercent() * 100).toFixed(1)}%`)
          .fontSize(12)
          .fontColor(this.theme.secondary)
      }
      .width('100%')

      Slider({
        value: this.displayPercent() * 100,
        min: 0,
        max: 100,
        step: 1
      })
        .selectedColor(this.theme.text)
        .trackColor(this.theme.secondary)
        .width('100%')
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
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    .backgroundColor(this.theme.barBg)
  }
}
