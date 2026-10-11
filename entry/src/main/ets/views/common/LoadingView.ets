import { AppColor, AppTheme } from '../../common/theme/AppTheme';

/** 加载中占位 */
@Component
export struct LoadingView {
  message: string = '加载中…';

  build() {
    Column({ space: AppTheme.GAP_S }) {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(AppColor.brand)
      Text(this.message)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppColor.textHint)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
