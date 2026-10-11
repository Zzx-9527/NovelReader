import { ReaderTheme } from '../../common/theme/AppTheme';

/** 阅读页顶栏：返回、章节名、菜单入口 */
@Component
export struct ReaderTopBar {
  title: string = '';
  theme: ReaderTheme = new ReaderTheme();
  onBack?: () => void;
  onMenu?: () => void;

  build() {
    Row() {
      Text('‹ 返回')
        .fontSize(16)
        .fontColor(this.theme.text)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          if (this.onBack !== undefined) {
            this.onBack();
          }
        })

      Text(this.title)
        .fontSize(14)
        .fontColor(this.theme.secondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      Text('目录')
        .fontSize(14)
        .fontColor(this.theme.text)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          if (this.onMenu !== undefined) {
            this.onMenu();
          }
        })
    }
    .width('100%')
    .height(52)
    .backgroundColor(this.theme.barBg)
    .alignItems(VerticalAlign.Center)
  }
}
