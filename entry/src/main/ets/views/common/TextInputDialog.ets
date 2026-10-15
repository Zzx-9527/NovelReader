import { AppColor, AppTheme } from '../../common/theme/AppTheme';

/**
 * 单行文本输入弹窗（新建/重命名分组等）。
 *
 * ⚠️ 为什么用**页面内 `Stack` 浮层**而不是 `@CustomDialog`：
 * 本项目已有成熟的浮层范式（`BookmarkDialog` / `SettingsPanel` / 目录页遮罩），
 * 都是"页面内 `if` 条件渲染 + 遮罩 + 统一配色"。`@CustomDialog` 要走独立的
 * `CustomDialogController`，还得把主题色另传一遍，没必要引入第二套机制。
 * 与 `BookmarkDialog` 保持同一形态，改一处就知道另一处怎么改。
 *
 * ⚠️ 输入值用**组件内 `@State`**，保存时才通过 `onConfirm` 交出去：
 * 让弹窗自己管理"正在输入什么"，父页面不必为每次按键重绘整页。
 *
 * ⚠️ 初值靠 `@Prop @Watch` 重置，不只在 `aboutToAppear` 里赋值：
 * ArkUI 可能**复用**同一个组件实例（`visible` 反复开关时），
 * 只写 `aboutToAppear` 会让第二次打开残留上一次的内容 ——
 * 与 `BookmarkDialog` 记的是同一个坑。
 */
@Component
export struct TextInputDialog {
  /** 标题，如"新建分组" */
  @Prop title: string = '';
  /** 输入框上方的说明文字，可空 */
  @Prop label: string = '';
  /** 占位提示 */
  @Prop placeholder: string = '';
  /**
   * 输入初值（重命名时传原名字）。
   *
   * ⚠️ `@Watch` 必须挂在**被观察的属性**（`initialValue`）上，
   * 不是挂在 `@State value` 上 —— 挂在自己身上只会在用户打字时回调，
   * 起不到"外部换了初值就重置输入框"的作用。
   */
  @Prop @Watch('onInitialValueChanged') initialValue: string = '';
  /** 确认按钮文案 */
  @Prop confirmText: string = '确定';
  /** 确认按钮是否用危险色（删除类操作用） */
  @Prop danger: boolean = false;

  /** 点确认：回传用户输入的原始字符串（由父页面 trim 与校验） */
  onConfirm?: (value: string) => void;
  onCancel?: () => void;

  /** 输入框当前内容（本地状态，确认时才交出去） */
  @State private value: string = '';
  /**
   * 输入框是否聚焦。
   *
   * ⚠️ 这是原实现**完全缺失**的一个状态：原来的输入框只有 `bgPage` 底色、
   * **没有任何边框**，看上去像页面上挖了一个洞；而且从默认态到聚焦态
   * 没有任何视觉变化，用户无法确认"光标到底在不在这里"。
   * `operate.md` 要求每个交互组件都有 default/hover/focus/active/disabled
   * 等状态，这里补的正是 focus。
   */
  @State private focused: boolean = false;

  aboutToAppear(): void {
    this.value = this.initialValue;
  }

  /** 外部换了初值（又打开一次、或换了一个分组）就把输入框重置 */
  onInitialValueChanged(): void {
    this.value = this.initialValue;
  }

  /** 去掉首尾空白后是否还有内容：空内容时确认按钮不可用 */
  private canConfirm(): boolean {
    return this.value.trim().length > 0;
  }

  private submit(): void {
    // 空内容不提交：调用方虽有兜底，但这里拦住能避免一次无意义的"失败"提示
    if (!this.canConfirm() || this.onConfirm === undefined) {
      return;
    }
    this.onConfirm(this.value.trim());
  }

  build() {
    Stack() {
      // 遮罩：铺满全屏，点了取消
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.mask)
        .onClick(() => {
          if (this.onCancel !== undefined) {
            this.onCancel();
          }
        })

      // 卡片本体：居中，左右留边
      Column({ space: AppTheme.GAP_M }) {
        Text(this.title)
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .width('100%')

        if (this.label.length > 0) {
          Text(this.label)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
            .width('100%')
        }

        TextInput({ text: this.value, placeholder: this.placeholder })
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppColor.textPrimary)
          .placeholderColor(AppColor.textHint)
          .backgroundColor(AppColor.bgPage)
          /**
           * ⚠️ 描边粗细**恒定 1.5vp**，只有颜色随聚焦变化。
           *
           * 若把"有没有边框 / 边框多粗"也跟着聚焦变，输入框的内容区
           * 会在聚焦瞬间缩进 1.5vp —— 文字与光标**跳一下**。
           * 这是最容易被忽略的一种状态切换代价：视觉上只是描边变了，
           * 但布局跟着动了。恒定粗细换来零位移。
           *
           * 聚焦色用 `accent`（点缀色）而不是某个"强调色"：
           * 焦点是"小面积、瞬时"的强调，正是点缀色的用途。
           */
          .border({
            width: 1.5,
            color: this.focused ? AppColor.accent : AppColor.divider
          })
          .borderRadius(AppTheme.ITEM_RADIUS)
          /**
           * ⚠️ 光标色必须显式设：默认是系统蓝，与本项目的点缀色 `#35597F`
           * 不是同一个蓝，会在一屏里出现两种主题色（深色模式下差别更明显）。
           * 这是"浏览器/系统原生表面也要跟着设计走"的那一类细节。
           */
          .caretColor(AppColor.accent)
          .onFocus(() => {
            this.focused = true;
          })
          .onBlur(() => {
            this.focused = false;
          })
          .width('100%')
          .maxLength(20)
          .onChange((input: string) => {
            this.value = input;
          })
          /**
           * ⚠️ 回车即确认：输入法是单行输入，用户敲完回车的直觉就是"提交"。
           * 不接这个回调的话回车没有任何反应，只能去点按钮。
           *
           * 回调声明是 `(enterKey: EnterKeyType, event: SubmitEvent) => void`，
           * 这里只声明用得到的第一个参数（与项目其他回调的写法一致）。
           */
          .onSubmit((enterKey: EnterKeyType) => {
            this.submit();
          })

        // 操作行：取消在左、确认在右（主操作靠外侧，与 BookmarkDialog 一致）
        Row({ space: AppTheme.GAP_M }) {
          Blank()
          Text('取消')
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              if (this.onCancel !== undefined) {
                this.onCancel();
              }
            })

          Text(this.confirmText)
            .fontSize(AppTheme.FONT_BODY)
            .fontWeight(FontWeight.Medium)
            // 危险操作用 danger 色；否则用主文字色
            .fontColor(this.danger ? AppColor.danger : AppColor.textPrimary)
            /**
             * ⚠️ 不可确认时置灰**且**不可点：置灰只是视觉，
             * 点击处理里还要再判一次（规则层自己保证，设计文档第 29 条）。
             */
            .opacity(this.canConfirm() ? 1 : 0.4)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              this.submit();
            })
        }
        .width('100%')
      }
      .width('88%')
      .padding(AppTheme.GAP_L)
      .borderRadius(AppTheme.CARD_RADIUS)
      /**
       * ⚠️ 背景必须**不透明**（`bgCard`）：本卡片压在页面之上，
       * 半透明会让下层内容透出来（同 `BookmarkDialog` 的约定）。
       */
      .backgroundColor(AppColor.bgCard)
    }
    .width('100%')
    .height('100%')
    // 居中：Stack 的默认对齐就是 Center，这里显式写出意图
    .alignContent(Alignment.Center)
  }
}
