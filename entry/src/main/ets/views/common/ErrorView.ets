import { AppColor, AppTheme } from '../../common/theme/AppTheme';

/**
 * 错误状态：解析失败 / 文件丢失 / 加载失败。
 * 失败文案由调用方传入，本组件不猜原因。
 */
@Component
export struct ErrorView {
  message: string = '出错了';
  /** 次要说明，例如"可尝试更换编码后重新解析" */
  hint: string = '';
  actionText: string = '重试';
  onRetry?: () => void;

  build() {
    Column({ space: AppTheme.GAP_M }) {
      Text('✗')
        .fontSize(28)
        .fontColor(AppColor.danger)
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
          .padding({ left: 32, right: 32 })
      }
      if (this.actionText.length > 0 && this.onRetry !== undefined) {
        Button(this.actionText)
          .fontSize(AppTheme.FONT_BODY)
          .backgroundColor(AppColor.brand)
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
