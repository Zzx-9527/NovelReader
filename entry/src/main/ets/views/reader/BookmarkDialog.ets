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
  /**
   * 阅读页配色。
   *
   * ⚠️ **必须是 `@Prop`**：普通成员只在创建时快照 ——
   * 弹窗开着时切"夜间"，它会保持旧配色（与顶栏/底栏同一个坑）。
   */
  @Prop theme: ReaderTheme = new ReaderTheme();
  /**
   * 弹窗用途：'bookmark'（加书签）或 'note'（写笔记）。
   *
   * ⚠️ 用同一个组件承载两种用途，而不是复制一个 `NoteDialog`：
   * 两者要展示与收集的东西**完全一样**（章节名 + 选文 + 备注输入框），
   * 差别只在标题、按钮文案、以及"备注是否必填"。
   * 复制一份的话，以后改布局（比如选文区加个"展开"）必然只改一处。
   *
   * 差异由本字段驱动：
   *  - 标题：加书签 / 写笔记；
   *  - 备注框提示语：书签是"可选"，笔记是"必填"；
   *  - 保存按钮可用性：笔记要求备注非空（空笔记在列表里什么都看不到）。
   */
  @Prop mode: string = 'bookmark';
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

  /** 是否"写笔记"用途（决定标题、提示语与必填规则） */
  private isNoteMode(): boolean {
    return this.mode === 'note';
  }

  private titleText(): string {
    return this.isNoteMode() ? '写笔记' : '加书签';
  }

  /**
   * 保存按钮是否可用。
   *
   * 书签：备注可选（只标位置也是有效操作）→ 恒可保存；
   * 笔记：备注必填 → 去空白后要有内容。
   */
  private canSave(): boolean {
    return this.isNoteMode() ? this.note.trim().length > 0 : true;
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
        Text(this.titleText())
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
          Text(this.isNoteMode() ? '笔记内容' : '备注')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(this.theme.secondary)
            .width('100%')
          TextArea({
            text: this.note,
            // 笔记是必填项，提示语要说清"必须写"；书签的备注才是可选的
            placeholder: this.isNoteMode() ? '写下你的想法…' : '写点备注（可留空）…'
          })
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
            /**
             * ⚠️ 笔记模式下备注为空时置灰**且不可提交**。
             *
             * 空笔记在笔记列表里是一行"什么都看不到"的记录，属于垃圾数据；
             * 而"想只标个位置"的需求由书签/划线承担，不必用空笔记表达。
             *
             * 置灰只是视觉，点击处理里**还要再判一次** ——
             * 规则层自己保证，不靠 UI 状态（设计文档第 29 条）。
             */
            .opacity(this.canSave() ? 1 : 0.4)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              if (!this.canSave()) {
                return;
              }
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
