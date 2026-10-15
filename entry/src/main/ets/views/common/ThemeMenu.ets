import { AppColor, AppTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';

/**
 * 主题化动作菜单 —— **全项目所有"平级选项挑选"弹窗的唯一入口**。
 *
 * 替代 `promptAction.showActionMenu()`（系统白底菜单）：
 * 那种菜单不跟随本项目的宣纸/朱砂主题，白色圆角卡片浮在暖纸色页面上
 * 像贴了一张打印纸。本组件用页面内 `Stack` 浮层实现同一个交互：
 * 遮罩 + 居中卡片 + 纵排选项列表，全部走 `AppColor` 令牌。
 *
 * ## 版面
 * ```
 *      ┌──────────────────┐
 *      │ 分组「测试」        │  ← 标题：衬线、可多行
 *      │ ──────────────    │  ← 标题下发丝线（有标题才画）
 *      │  · 打开分组         │  ← 选项行：44vp 高、衬线文字
 *      │  · 加入书籍         │     当前项左侧朱色小点（current 标记）
 *      │  · 重命名           │     危险项文字用 danger 色
 *      │  · 解散分组         │  ← 行间发丝线
 *      └──────────────────┘
 * ```
 *
 * ⚠️ 为什么用页面内浮层而不是 `@CustomDialog`：
 * 本项目已有成熟的浮层范式（TextInputDialog / BookmarkDialog / SettingsPanel），
 * 都是"页面内 `if` 条件渲染 + 遮罩 + 统一配色"。`@CustomDialog` 要走独立的
 * `CustomDialogController`，主题色还得另传一遍，没必要引入第二套机制。
 *
 * ⚠️ 回调模型与 `showActionMenu` 的 Promise **不同**：本组件用
 * `onPick(index)` 单回调，**不设"取消"按钮**（点遮罩 = 取消，由 onClose 承担）——
 * 系统菜单把"取消"列为最后一项是历史包袱：遮罩已经是更自然的取消动作，
 * 再放一行"取消"是同一动作的第二个入口（设计文档禁止"同一信息两处显示"）。
 */
@Component
export struct ThemeMenu {
  /** 标题（如 书名 / 分组名 / "书架排序"）；空串时不渲染标题与分隔线 */
  @Prop title: string = '';
  /** 选项文案数组（顺序即展示顺序） */
  @Prop options: string[] = [];
  /**
   * 危险项的下标集合（JSON 数组字符串形式传入 —— ArkTS 的 `@Prop`
   * 对 `Set`/数组字面量的深拷贝行为不稳，用字符串最保险）。
   * 形如 "2,3"；空串表示没有危险项。
   */
  @Prop dangerIndexes: string = '';
  /**
   * 当前项的下标（如 分组选择器里的"当前"项 / 编码选择器里的当前编码）。
   * -1 表示没有当前项。当前项左侧画一枚朱色小点。
   */
  @Prop currentIndex: number = -1;

  /** 点第 index 项（父页面按下标分发动作，与原 showActionMenu 的 then 一致） */
  onPick?: (index: number) => void;
  /** 点遮罩（= 用户取消） */
  onClose?: () => void;

  /** dangerIndexes 是否包含 index（"2,3" 里找 "2"） */
  private isDanger(index: number): boolean {
    if (this.dangerIndexes.length === 0) {
      return false;
    }
    return this.dangerIndexes.split(',').some((s: string) => s === `${index}`);
  }

  /** 某一项是否是"当前"项（画朱点） */
  private isCurrent(index: number): boolean {
    return this.currentIndex === index;
  }

  build() {
    Stack() {
      // 遮罩：铺满全屏，点了取消
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.mask)
        .onClick(() => {
          if (this.onClose !== undefined) {
            this.onClose();
          }
        })

      // 卡片本体：居中，宽度 80%（比输入弹窗略窄：列表菜单内容更简单）
      Column() {
        // 顶部一道朱色细线：整个弹窗唯一的彩色大面 —— "印"落在纸上的感觉
        Row()
          .width('100%')
          .height(2.5)
          .backgroundColor(AppColor.accent)
          .opacity(0.85)

        // 标题（有才画）+ 发丝线
        if (this.title.length > 0) {
          Row({ space: 8 }) {
            /**
             * 朱砂方印：一枚 8vp 的小方块旋转 45°（菱形），
             * 是标题的"落款"—— 全 app 的题字都带这个意象（书签带、题花线）。
             */
            Column()
              .width(8)
              .height(8)
              .backgroundColor(AppColor.accent)
              .opacity(0.9)
              .rotate({ angle: 45 })
              .margin({ top: 1 })

            Text(this.title)
              .fontSize(AppTheme.FONT_SUBTITLE)
              .fontWeight(FontWeight.Medium)
              // 标题落衬线 —— 与全 app 的题字同一套语汇
              .fontFamily(AppFont.titleFamily())
              .letterSpacing(0.5)
              .fontColor(AppColor.textPrimary)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 18, right: 18, top: 15, bottom: 13 })

          Row()
            .width('100%')
            .height(AppTheme.HAIRLINE)
            .backgroundColor(AppColor.divider)
        }

        /**
         * 选项列表。
         *
         * ⚠️ `ForEach` 的键含**文案**：选项集合变化时（如"切换为列表"↔
         * "切换为网格"）整行重建，行内的状态（无）不需要保留。
         *
         * ⚠️ 行**内联写死在 ForEach 里**（不是带参 @Builder）：
         * 每行的危险态/当前态都由下标现算，ForEach 已参数化了全部差异。
         */
        ForEach(this.options, (label: string, index: number) => {
          Row({ space: 10 }) {
            // 当前项标记：朱色小点（无当前项或非当前行不画）
            Column()
              .width(5)
              .height(5)
              .borderRadius(3)
              .backgroundColor(AppColor.accent)
              .opacity(this.isCurrent(index) ? 1 : 0)

            Text(label)
              .fontSize(AppTheme.FONT_BODY)
              .fontWeight(this.isCurrent(index) ? FontWeight.Medium : FontWeight.Normal)
              // 危险项用 danger 色，其余正常墨色
              .fontColor(this.isDanger(index) ? AppColor.danger : AppColor.textPrimary)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            // 行尾「›」角标：淡墨色，暗示"这一行可以点" —— 与我的页的 IconChevron 同一语汇
            Text('›')
              .fontSize(15)
              .fontColor(AppColor.textHint)
              .opacity(0.55)
          }
          .width('100%')
          .height(48)
          .padding({ left: 18, right: 14 })
          .alignItems(VerticalAlign.Center)
          .border({
            // 行间发丝线：第一行上方不画（标题的线已承担分隔），
            // 用上边框而不是行间距 —— 与账目行同一语汇
            width: { top: index > 0 || this.title.length === 0 ? AppTheme.HAIRLINE : 0 },
            color: AppColor.divider
          })
          .onClick(() => {
            if (this.onPick !== undefined) {
              this.onPick(index);
            }
          })
        }, (label: string, index: number) => `opt_${index}_${label}`)
      }
      .width('80%')
      .backgroundColor(AppColor.bgCard)
      .borderRadius(AppTheme.CARD_RADIUS)
      /**
       * 发丝外框：暖纸页面上纯白卡片只靠阴影分界会"飘"；
       * 一道 1vp 的暖灰框把纸卡"压"在页面上 —— 与列表卡/信息卡同一语汇。
       */
      .border({ width: AppTheme.HAIRLINE, color: AppColor.divider })
      .shadow({
        radius: 28,
        color: 'rgba(80, 64, 40, 0.28)',
        offsetX: 0,
        offsetY: 10
      })
      .clip(true)
      // 选项多时（编码选择器 6 项 + 标题）不能顶出屏幕
      .constraintSize({ maxHeight: '70%' })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
