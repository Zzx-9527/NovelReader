import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { MarkEmpty } from './Marks';

/**
 * 空状态：无书籍 / 无书签 / 无搜索结果等。
 *
 * ## 本次改动：给空状态一个"图形主语"
 *
 * 原实现只有一个 16vp 的标题、一段 12vp 的说明和一个按钮 —— 整屏没有任何
 * 图形，于是这一屏读起来像"页面没加载完"。空状态是**新用户看到的第一屏**，
 * 它的职责是教会用户这个界面怎么用，而不是礼貌地说"没有内容"。
 *
 * 现在补一个纯几何标记（三张叠放的纸页 + 一条点缀色书签带，见 `MarkEmpty`），
 * 并把文案分成**两级**：主标题（16vp、`text_secondary`）说"是什么状态"，
 * 说明（12vp、`text_hint`）说"接下来做什么"。层级从字号与颜色两处同时建立，
 * 不是靠一句话包办。
 *
 * ⚠️ 标记颜色全部取自 `AppColor` 令牌，且由**三段不透明度**造纵深 ——
 * 没有新增任何颜色，深浅模式自动跟随。刻意不用插画、不用 emoji：
 * 它们是"画的图"而不是"几何形状"，质感与这个界面不搭。
 */
@Component
export struct EmptyView {
  title: string = '这里还什么都没有';
  hint: string = '';
  actionText: string = '';
  onAction?: () => void;
  /**
   * 是否显示几何标记。
   *
   * ⚠️ 默认开、但留了关闭开关：某些空状态里"叠放的纸页"语义并不贴切
   * （例如将来做"搜索无结果"时，纸页不如一个放大镜）。与其在组件里
   * 堆一串 `if`，不如把选择权交给调用方 —— 调用方才知道自己在说什么。
   */
  showMark: boolean = true;

  build() {
    Column() {
      if (this.showMark) {
        /**
         * ⚠️ 标记与标题之间留 **20vp**，比标题与说明之间的 6vp 大得多。
         *
         * 这不是随手取的：间距本身在表达"谁属于谁"。
         * 标记与标题同属"这一屏在说什么"这一组，说明与按钮属于下一组 ——
         * 组内紧、组间松，层级就出来了，不必靠字号或颜色去硬分。
         */
        Column() {
          MarkEmpty()
        }
        .margin({ bottom: 20 })
      }

      Text(this.title)
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontColor(AppColor.textSecondary)
        .textAlign(TextAlign.Center)

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .textAlign(TextAlign.Center)
          .lineHeight(20)
          .padding({ left: 32, right: 32 })
          .margin({ top: 6 })
      }

      if (this.actionText.length > 0) {
        // 中性填充按钮；字色必须显式设，否则深色模式下是"白底白字"
        Button(this.actionText)
          .fontSize(AppTheme.FONT_BODY)
          .backgroundColor(AppColor.primary)
          .fontColor(AppColor.onPrimary)
          .margin({ top: 14 })
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
