import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { MarkError } from './Marks';

/**
 * 错误状态：解析失败 / 文件丢失 / 加载失败。
 * 失败文案由调用方传入，本组件不猜原因。
 *
 * ## 本次改动
 *
 * 1. **主视觉换成画出来的标记**（`MarkError`：描边圆 + 感叹号）。
 *    原来是一个 28vp 的文本字形 `✗` —— 它的粗细、大小、基线位置全都随字体变化，
 *    而它恰恰是整屏错误态里唯一有"形状"的东西。圆是组件画的（尺寸确定），
 *    感叹号这个字符在任何字体里画法都一致。
 * 2. **层级重排**：错误信息是主角（`text_primary`、14vp、居中），
 *    恢复建议是配角（`text_hint`、12vp），两者之间留 6vp；
 *    标记与文案之间留 16vp。原实现的间距一律是 `GAP_M`(12)，
 *    三段的"分组关系"因此读不出来。
 * 3. 按钮与文案之间留 14vp，与 `EmptyView` 完全一致 ——
 *    同一个 App 里"标记 → 文案 → 按钮"的距离不该有两种。
 */
@Component
export struct ErrorView {
  message: string = '出错了';
  /** 次要说明，例如"可尝试更换编码后重新解析" */
  hint: string = '';
  actionText: string = '重试';
  onRetry?: () => void;

  build() {
    Column() {
      Column() {
        MarkError()
      }
      .margin({ bottom: 16 })

      Text(this.message)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppColor.textPrimary)
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .textAlign(TextAlign.Center)
          .lineHeight(20)
          .padding({ left: 32, right: 32 })
          .margin({ top: 6 })
      }

      if (this.actionText.length > 0 && this.onRetry !== undefined) {
        // 中性填充按钮；字色必须显式设，否则深色模式下是"白底黑字"
        Button(this.actionText)
          .fontSize(AppTheme.FONT_BODY)
          .backgroundColor(AppColor.primary)
          .fontColor(AppColor.onPrimary)
          .margin({ top: 14 })
          .onClick(() => {
            if (this.onRetry !== undefined) {
              this.onRetry();
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
