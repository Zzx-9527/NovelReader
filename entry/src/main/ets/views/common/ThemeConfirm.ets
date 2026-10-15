import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';

/**
 * 主题化确认弹窗 —— **全项目所有"是非确认"弹窗的唯一入口**。
 *
 * 替代 `promptAction.showDialog()` 与 `getUIContext().showAlertDialog()`：
 * 系统确认框是冷白的圆角卡片 + 蓝色按钮，与本项目的宣纸/朱砂主题无关，
 * 且 `AlertDialog` 的按钮色只收 string 字面量（`AppColorLiteral` 因此存在）。
 * 本组件把确认框也收进令牌体系：居中纸卡、衬线标题、朱砂描边的危险按钮。
 *
 * ## 版面
 * ```
 *      ┌──────────────────────┐
 *      │ 确认重新分章？           │  ← 标题：衬线
 *      │ 这本书的 3 条书签/笔记    │  ← 说明文字（可多行）
 *      │ 会一并被删除…            │
 *      │                        │
 *      │ [  取消  ] [ 删除并分章 ] │  ← 取消描边；确认主按钮
 *      └──────────────────────┘     danger 时朱砂实心
 * ```
 *
 * ⚠️ 按钮语义与原 `showDialog` 对齐：**确认永远在右**、取消在左；
 * 危险操作由调用方传 `danger: true`，此时确认按钮用 danger 底 +
 * onPrimary 字色（而不是让每个调用方各自拼 color 字面量）。
 *
 * ⚠️ 返回模型与 Promise 版 `showDialog` 不同：本组件用
 * `onConfirm` / `onCancel` 双回调，调用方不用再解析 `result.index`
 * —— "第 0 个是 positive 第 1 个是 negative"的那种顺序约定彻底消失。
 */
@Component
export struct ThemeConfirm {
  /** 标题（衬线，如"确认重新分章？"） */
  @Prop title: string = '';
  /** 说明文字（可多行，讲清"会发生什么、丢不丢东西"） */
  @Prop message: string = '';
  /** 确认按钮文案（右） */
  @Prop confirmText: string = '确定';
  /** 危险操作：确认按钮用 danger 实心 */
  @Prop danger: boolean = false;

  onConfirm?: () => void;
  onCancel?: () => void;

  build() {
    Stack() {
      // 遮罩：铺满全屏，点了取消（autoCancel 语义）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.mask)
        .onClick(() => {
          if (this.onCancel !== undefined) {
            this.onCancel();
          }
        })

      /**
       * 卡片本体：外层 Column 全宽（朱线贴顶、裁切圆角），
       * 内层 Column 带内边距装内容 —— 朱线不能靠负 margin 硬贴，
       * 那在部分实现上会悬空到圆角外。
       */
      Column() {
        // 顶部一道朱色细线：与 ThemeMenu 同一语汇 —— "印"落在纸上的感觉
        Row()
          .width('100%')
          .height(2.5)
          .backgroundColor(AppColor.accent)
          .opacity(0.85)

        Column({ space: AppTheme.GAP_M }) {
          Row({ space: 8 }) {
            /**
             * 朱砂菱形落款：标题前一枚 8vp 的小印 —— 与 ThemeMenu 同一语汇。
             * 危险确认时换 danger 色：颜色本身就在说"这一步要小心"。
             */
            Column()
              .width(8)
              .height(8)
              .backgroundColor(this.danger ? AppColor.danger : AppColor.accent)
              .opacity(0.9)
              .rotate({ angle: 45 })
              .margin({ top: 1 })

            Text(this.title)
              .fontSize(AppTheme.FONT_SUBTITLE)
              .fontWeight(FontWeight.Medium)
              .fontFamily(AppFont.titleFamily())
              .letterSpacing(0.5)
              .fontColor(AppColor.textPrimary)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(AppTheme.FONT_CAPTION)
              .lineHeight(19)
              .fontColor(AppColor.textSecondary)
              .width('100%')
          }

          // 按钮行：取消（描边）在左、确认（实心）在右 —— 与导入确认页同一套
          Row({ space: AppTheme.GAP_M }) {
            Text('取消')
              .fontSize(AppTheme.FONT_BODY)
              .fontColor(AppColor.textSecondary)
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .padding({ top: 10, bottom: 10 })
              .borderRadius(AppTheme.ITEM_RADIUS)
              .border({ width: AppTheme.HAIRLINE, color: AppColor.divider })
              .onClick(() => {
                if (this.onCancel !== undefined) {
                  this.onCancel();
                }
              })

            Text(this.confirmText)
              .fontSize(AppTheme.FONT_BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.onPrimary)
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .padding({ top: 10, bottom: 10 })
              .borderRadius(AppTheme.ITEM_RADIUS)
              // 普通确认：墨色实心（primary，中性强调）；
              // 危险确认：朱砂实心 —— "这一步不可逆"用颜色提前说
              .backgroundColor(this.danger ? AppColor.danger : AppColor.primary)
              .onClick(() => {
                if (this.onConfirm !== undefined) {
                  this.onConfirm();
                }
              })
          }
          .width('100%')
          .margin({ top: 4 })
        }
        .width('100%')
        .padding(AppTheme.GAP_L)
      }
      .width('80%')
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)
      .clip(true)
      // 发丝外框 + 投影：与 ThemeMenu 同一套"纸卡压在页面上"的处理
      .border({ width: AppTheme.HAIRLINE, color: AppColor.divider })
      .shadow({
        radius: 28,
        color: 'rgba(80, 64, 40, 0.28)',
        offsetX: 0,
        offsetY: 10
      })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
