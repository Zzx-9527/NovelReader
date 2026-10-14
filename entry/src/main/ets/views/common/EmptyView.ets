import { AppColor, AppTheme } from '../../common/theme/AppTheme';

/** 空状态：无书籍 / 无书签等 */
@Component
export struct EmptyView {
  title: string = '这里还什么都没有';
  hint: string = '';
  actionText: string = '';
  onAction?: () => void;

  build() {
    Column({ space: AppTheme.GAP_M }) {
      Text(this.title)
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontColor(AppColor.textSecondary)
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .textAlign(TextAlign.Center)
          .padding({ left: 32, right: 32 })
      }
      if (this.actionText.length > 0) {
        // 中性填充按钮；字色必须显式设，否则深色模式下是"白底白字"
        Button(this.actionText)
          .fontSize(AppTheme.FONT_BODY)
          .backgroundColor(AppColor.primary)
          .fontColor(AppColor.onPrimary)
          .onClick(() => {
            if (this.onAction !== undefined) {
              this.onAction();
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
