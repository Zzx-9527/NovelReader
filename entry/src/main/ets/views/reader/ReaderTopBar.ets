import { ReaderTheme } from '../../common/theme/AppTheme';

/**
 * 阅读页顶栏：返回、章节名、书签、目录入口。
 * 章节名需 `@Prop` 才会随翻页更新。
 */
@Component
export struct ReaderTopBar {
  @Prop title: string = '';
  theme: ReaderTheme = new ReaderTheme();
  onBack?: () => void;
  /** 点"目录"：跳转到独立的目录页（`ReaderCatalogPage`） */
  onMenu?: () => void;
  /** 点"书签"：在当前位置切换书签（加/取消） */
  onBookmark?: () => void;

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

      /**
       * 加书签。
       *
       * ⚠️ 这里**不显示**"当前是否已加书签"的状态：
       * 书签记的是**当前页起始偏移**，翻一页偏移就变了，
       * 要如实反映状态就得在每次翻页后异步查库 —— 既费 IO，
       * 又容易和翻页竞态（查到的是上一页的结果）。
       * 改成"点击即切换 + toast 反馈"，行为确定、没有状态可失真。
       * 已加的书签在目录页的"书签"Tab 里能看到。
       */
      Text('书签')
        .fontSize(14)
        .fontColor(this.theme.text)
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .onClick(() => {
          if (this.onBookmark !== undefined) {
            this.onBookmark();
          }
        })

      Text('目录')
        .fontSize(14)
        .fontColor(this.theme.text)
        .padding({ left: 10, right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          if (this.onMenu !== undefined) {
            this.onMenu();
          }
        })
    }
    .width('100%')
    .height(52)
    /**
     * ⚠️ 背景必须**不透明**（`theme.bg`，不用半透明的 `theme.barBg`）。
     *
     * 顶栏弹出时下方压着正文，半透明会让正文文字从它后面透出来
     * （实测：标题上叠着正文的"修"字，看起来像渲染错误）。
     *
     * 全 app 的阅读页浮层统一用不透明底色：顶栏、菜单底栏、设置面板、常驻底栏
     * 四者一致，不会出现"上面透、下面不透"的割裂感。
     */
    .backgroundColor(this.theme.bg)
    .alignItems(VerticalAlign.Center)
  }
}
