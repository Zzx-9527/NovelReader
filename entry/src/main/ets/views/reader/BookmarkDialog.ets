import { AppColor, AppTheme, ReaderTheme } from '../../common/theme/AppTheme';
import { BookmarkDraft } from '../../viewmodels/ReaderState';

/**
 * 加书签弹窗（长按选中正文 → 菜单「书签」后出现）。
 *
 * 版面：**全屏遮罩 + 屏幕居中的卡片**，卡片自上而下三块 ——
 * ```
 *         加书签
 *  ─────────────────────────
 *  章节    第677章: 修炉        ← ① 第几章
 *  ┌───────────────────────┐
 *  │ 选中内容（只读，可滚）  │   ← ② 选择的内容
 *  └───────────────────────┘
 *  ┌───────────────────────┐
 *  │ 写点备注…（可输入）     │   ← ③ 备注
 *  └───────────────────────┘
 *               取消   保存
 * ```
 *
 * ⚠️ 是**居中卡片**，不是从底部升起的抽屉（用户明确要求）。
 * 好处之一：不贴底就不必为手势条留安全区。
 *
 * ⚠️ 为什么用页面内 `Stack` 浮层而不是 `@CustomDialog`：
 * 本项目已有成熟的浮层范式（`SettingsPanel` / 目录页遮罩层），
 * 都是"页面内 `if` 条件渲染 + 遮罩 + `ReaderTheme` 配色"；
 * `@CustomDialog` 要走独立的 `CustomDialogController`，
 * 主题色还得另传一遍，没必要引入第二套机制。
 *
 * ⚠️ 配色走 `ReaderTheme`（同设置面板）：夜间/羊皮纸主题下不能变成白板。
 *
 * ⚠️ `draft` 用 `@Prop` 接收：它是普通 class，`@Prop` 会深拷贝 ——
 * 正是想要的，卡片里改备注不会顺着共享引用改到阅读页的状态。
 */
@Component
export struct BookmarkDialog {
  /**
   * 待确认的书签内容（章节名 / 选文 / 备注初值）。
   *
   * ⚠️ `@Watch` 必须挂在**被观察的属性**上（`draft`），不是挂在 `note` 上 ——
   * 挂在 `note` 只会在用户打字时回调，起不到"草稿换了就重置输入框"的作用。
   */
  @Prop @Watch('onDraftChanged') draft: BookmarkDraft = new BookmarkDraft();
  theme: ReaderTheme = new ReaderTheme();
  /** 点"保存"：回传用户填好的备注 */
  onSave?: (note: string) => void;
  /** 点"取消"或遮罩 */
  onCancel?: () => void;

  /**
   * 备注输入框的当前内容（本地状态，保存时才交出去）。
   *
   * ⚠️ 不能只在 `aboutToAppear` 里初始化：ArkUI 可能**复用**同一个组件实例
   * （`bookmarkVisible` 反复开关时），那样第二次打开会残留上一次输入的备注 ——
   * 用户看到的是别人的内容。所以靠 `onDraftChanged` 每次重置。
   */
  @State private note: string = '';

  aboutToAppear(): void {
    // 用草稿里的备注做初值（同位置已有书签时能接着改）
    this.note = this.draft.note;
  }

  /** 每次草稿换新（= 又选了一段文字）就把输入框重置成该草稿的备注 */
  onDraftChanged(): void {
    this.note = this.draft.note;
  }

  build() {
    /**
     * 版面：**全屏遮罩 + 居中的卡片**（不是从底部升起的抽屉）。
     *
     * ⚠️ 用 `Stack` 让卡片居中，而不是 `Column` + `layoutWeight` 顶到底部：
     * 用户明确要求"在屏幕中间显示的那种"。居中还有一个实际好处 ——
     * 弹窗不贴底，就**不需要**为手势条留底部安全区，
     * 也就不会出现"卡片被顶高、下面空一截"的观感问题。
     */
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

      // 卡片本体：居中，左右留边，宽度自适应但不超过屏宽
      Column({ space: AppTheme.GAP_M }) {
        Text('加书签')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.text)
          .width('100%')

        // ① 第几章
        Row() {
          Text('章节')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(this.theme.secondary)
          Text(this.draft.chapterLabel)
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(this.theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ left: AppTheme.GAP_S })
        }
        .width('100%')

        // ② 选择的内容：只读展示。用 Scroll 兜住长段落，别把卡片撑爆
        Column({ space: 4 }) {
          Text('选中内容')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(this.theme.secondary)
            .width('100%')
          Scroll() {
            Text(this.draft.selectedText.length > 0 ? this.draft.selectedText : '（未选中文字，仅记录当前位置）')
              .fontSize(AppTheme.FONT_BODY)
              .fontColor(this.theme.text)
              .width('100%')
          }
          .scrollBar(BarState.Off)
          .constraintSize({ maxHeight: 120 })
          .width('100%')
          .align(Alignment.TopStart)
        }
        .width('100%')
        .padding(AppTheme.GAP_M)
        .borderRadius(AppTheme.ITEM_RADIUS)
        // 用半透明底色区分"只读展示区"与下面可输入的备注框。
        // `barBg` 用在这里是安全的：它下方是本卡片的**不透明**底色，不会透出正文
        .backgroundColor(this.theme.barBg)
        .alignItems(HorizontalAlign.Start)

        // ③ 备注：可输入
        Column({ space: 4 }) {
          Text('备注')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(this.theme.secondary)
            .width('100%')
          TextArea({ text: this.note, placeholder: '写点备注…' })
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(this.theme.text)
            .placeholderColor(this.theme.secondary)
            .backgroundColor(Color.Transparent)
            .width('100%')
            .height(72)
            .onChange((value: string) => {
              this.note = value;
            })
        }
        .width('100%')
        .padding(AppTheme.GAP_M)
        .borderRadius(AppTheme.ITEM_RADIUS)
        .backgroundColor(this.theme.barBg)
        .alignItems(HorizontalAlign.Start)

        // 操作行：右对齐，取消在左、保存在右（主操作靠外侧，符合通用习惯）
        Row({ space: AppTheme.GAP_M }) {
          Blank()
          Text('取消')
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(this.theme.secondary)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              if (this.onCancel !== undefined) {
                this.onCancel();
              }
            })
          Text('保存')
            .fontSize(AppTheme.FONT_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.text)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              if (this.onSave !== undefined) {
                this.onSave(this.note);
              }
            })
        }
        .width('100%')
      }
      .width('88%')
      .padding(AppTheme.GAP_L)
      // 四角都圆：居中卡片不是贴边的抽屉，不需要只圆上两角
      .borderRadius(AppTheme.CARD_RADIUS)
      /**
       * ⚠️ 背景必须**不透明**（`theme.bg`）：本卡片压在正文之上，
       * 半透明会让正文文字从后面透出来（同设置面板/菜单底栏的约定）。
       */
      .backgroundColor(this.theme.bg)
      // 卡片内容多时（长选文 + 备注）不能顶出屏幕
      .constraintSize({ maxHeight: '80%' })
    }
    .width('100%')
    .height('100%')
    // 居中：Stack 的默认对齐就是 Center，这里显式写出意图
    .alignContent(Alignment.Center)
  }
}
