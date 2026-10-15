import { AppTheme, ReaderTheme } from '../../common/theme/AppTheme';

/**
 * 书名左右各留的安全间距（vp）。
 *
 * ⚠️ 存在的理由：书名要**相对整屏居中**（用 `Stack` 叠在左右按钮之下），
 * 于是它理论上会铺满整宽、可能被"‹ 返回"和刷新图标压住。
 * 这个间距保证长书名在**碰到两侧控件之前**就先省略号截断。
 *
 * ⚠️ 它是**固定的安全间距**，不是"量出返回按钮有多宽"——
 * 后者会随字号/字体变化而失效（目录页的注释里记过这个教训：
 * 想用魔法数字对齐按钮宽度，迟早对不上）。
 * 取 72：比"‹ 返回"（约 68vp）和刷新图标（约 46vp）都宽，两边都够用。
 */
const TITLE_SIDE_GUTTER: number = 72;

/**
 * 阅读页顶栏：返回、**书名**、刷新。
 *
 * ⚠️ 中间显示的是**书名**，不再是章节名（用户要求）：
 * 章节名已经由阅读页的**常驻底栏**承担（见 `ReaderPage.buildReaderFooter`），
 * 顶栏再显示一次属于重复；而"我在读哪本书"是菜单弹出时更想确认的信息。
 *
 * ⚠️ 右上角原为"目录"，现改为**刷新**；目录入口已移到菜单底栏
 * （见 `ReaderBottomBar` 的"目录 / 夜间 / 设置"三块）。
 *
 * ⚠️ 这里**没有**书签按钮：加书签走"长按正文选中 → 菜单里的书签"
 * （见 `ReaderPage` 的 `buildTextEditMenu`），与系统复制同一个入口。
 */
@Component
export struct ReaderTopBar {
  /** 书名。用 `@Prop` 而非普通成员：普通成员只在创建时快照，换书不会更新 */
  @Prop title: string = '';
  /**
   * 阅读页配色。
   *
   * ⚠️ **必须是 `@Prop`**（本项目踩过两次：书架卡片、以及这里）：
   * 普通成员只在组件**创建时**取一次快照，之后父组件状态再变也不会同步。
   * 表现是"点了夜间，正文变黑了，顶栏/底栏还是白的"——
   * 因为正文背景由页面自己画（每次 build 现算），
   * 而这两条栏的配色是**创建时**拷进来的旧值。
   * 关掉菜单再打开之所以"又正常了"，正是因为 `if (menuVisible)` 让组件
   * 被销毁重建、重新取了一次快照 —— 这个现象本身就是这条规则的证据。
   */
  @Prop theme: ReaderTheme = new ReaderTheme();
  onBack?: () => void;
  /** 点"刷新"：重读当前章正文并重算分页 */
  onRefresh?: () => void;

  build() {
    /**
     * ⚠️ 用 `Stack` 而不是 `Row`：要让书名**相对整屏居中**（用户反馈"不居中"）。
     *
     * 为什么 `Row` + `layoutWeight(1)` 会偏：那种写法下书名占的是
     * "整宽 − 返回按钮宽 − 刷新图标宽"这块**剩余空间**，再在其中居中 ——
     * 而左右两侧控件宽度**不相等**（"‹ 返回"约 68vp，刷新图标约 46vp），
     * 剩余空间是 [68, W−46]，它的中心 = (68 + W − 46) / 2 = W/2 + 11，
     * 即比屏幕中心**偏右约 11vp**（这也正是用户要求"再往左边一点点"的原因）。
     *
     * `Stack` 的解法：让书名铺满整宽、自己居中（相对屏幕，天然对称），
     * 左右两个控件叠在它**上层**。这也是目录页 `buildHeader` 用的同一套做法
     * （那边的注释记着"想在 Row 里补正就得写一个与返回按钮等宽的魔法数字，
     * 而那个宽度会随字号、字体而变 —— 迟早对不上"）。
     *
     * ⚠️ 层级顺序：书名**先**画（在下层），返回与刷新**后**画（在上层）。
     * 这样它们的点击不会被书名盖住 —— `HitTestMode.Default` 下
     * 后画的节点优先命中（设计文档第 11 条）。
     */
    Stack({ alignContent: Alignment.Center }) {
      /**
       * 书名：铺满整宽 + 文本居中 = **相对屏幕居中**。
       *
       * ⚠️ 左右留 `TITLE_SIDE_GUTTER` 的内边距：书名铺满整宽后，
       * 长书名会伸到左右按钮下面被压住。留出这段安全区，
       * 文本就会在碰到按钮之前先省略号截断（`textOverflow` 生效于内容区）。
       *
       * ⚠️ 字号 `AppTheme.FONT_SUBTITLE`(16)，**不加粗**（用户要求）。
       * 曾短暂加过 `FontWeight.Bold`，用户看后要求去掉 ——
       * 顶栏是"我在读哪本书"的**环境信息**，不是需要强调的标题。
       *
       * ⚠️ 颜色保持 `theme.text`（正文色），不用 `secondary`(灰)：
       * 左右"返回"与刷新图标都是 `theme.text`，只有中间发灰会显得更弱。
       */
      Text(this.title)
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontColor(this.theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ left: TITLE_SIDE_GUTTER, right: TITLE_SIDE_GUTTER })

      /**
       * **上层**：铺满整宽的行，只为把左右两个控件顶到两端。
       *
       * ⚠️ 放在书名**之后**画 = 叠在书名上层。这样"返回"和刷新图标
       * 一定拿得到点击（`HitTestMode.Default` 下后画的节点优先命中，
       * 设计文档第 11 条）—— 若反过来把书名叠在上面，它会挡住两侧的点击。
       *
       * ⚠️ 用 `Blank()` 撑开而不是 `justifyContent(SpaceBetween)`：
       * `Blank` 会吃掉中间全部剩余空间，两端自然对齐。
       * 它本身不是可点节点，所以中间那块区域是"透明的"，
       * 不会把书名的显示挡出问题（书名本来也不可点）。
       */
      Row() {
        Text('‹ 返回')
          /**
           * ⚠️ 字号走 `AppTheme.FONT_BAR_TEXT`，与菜单底栏**同源**。
           * 用户要求"底部状态栏与顶部返回的字体对应"—— 由同一个常量保证，
           * 而不是两处各写一个 16 靠巧合相等（设计文档第 28 条）。
           */
          .fontSize(AppTheme.FONT_BAR_TEXT)
          .fontColor(this.theme.text)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            if (this.onBack !== undefined) {
              this.onBack();
            }
          })

        Blank()

        /**
         * 刷新：重新从文件读取当前章、丢掉旧的解码与分页缓存后重排。
         *
         * 用文本字形 `↻`（U+21BB，Arrows 区）而不是图片资源：
         * 本项目全程零图片依赖（封面也是文字占位），引一个图标就要多一份
         * `resources/base/media` 资源，且要维护深浅色两套。
         * 字形跟随 `fontColor` 走，与主题天然一致。
         *
         * ⚠️ 刻意不用 `⟳`（U+27F3）：它属于 "Miscellaneous Symbols and Arrows"，
         * 部分字体缺字会渲染成豆腐块；`↻` 在箭头区，覆盖面广得多。
         *
         * ⚠️ **旋转 90° 让开口朝右**（用户要求）：
         * `↻` 的字形开口默认朝上，靠 `.rotate` 转到右侧，而不是去挑另一个字形 ——
         * 不同字体对"开口朝哪"的画法并不一致，靠换码点等于把结果交给字体；
         * 旋转是**确定性**的，且与字体无关。
         * 若某设备上方向反了（开口朝左），把下面的角度改成 `270` 即可。
         *
         * ⚠️ 旋转后视觉尺寸不变，但**布局盒子仍是原尺寸** ——
         * 所以给了左右各 12 的内边距，避免箭头旋转后贴到屏幕边缘被裁。
         */
        Text('↻')
          .fontSize(22)
          .fontColor(this.theme.text)
          .rotate({ angle: 90 })
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .onClick(() => {
            if (this.onRefresh !== undefined) {
              this.onRefresh();
            }
          })
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Center)

      /**
       * 栏底发丝线。
       *
       * ⚠️ 新增这一条的判据：顶栏弹出时它**压着正文**，而它的底色与
       * 正文底色常常是同一个（浅色主题下都是 #FFFFFF）——
       * 于是"顶栏到哪里结束"只靠正文文字的截断位置暗示，读起来是含混的。
       * 一条 30% 的 `theme.secondary` 说清边界，且因为用的是 `secondary`
       * 而不是 `AppColor.divider`，在羊皮纸/护眼/夜间三套主题下都不会
       * 露出不搭的系统色。
       *
       * ⚠️ 不透明度走 `AppTheme.READER_RULE_ALPHA`：与常驻底栏的分隔线**同源**。
       * 两条线一个在顶一个在底，粗细与深浅必须一致，否则整页会显得歪。
       *
       * ⚠️ 用 `position({ left, right, bottom })` 定位，而**不是**把本栏改成
       * `Column { Stack + 线 }`：改结构要给整个栈内的子节点重新缩进一级，
       * 而这个文件里每一行都带着说明它为什么存在的注释 —— 大范围重排
       * 会让 diff 淹没真正的改动。`position` 的 `Edges` 形式不参与布局，
       * 只是把这根线钉在栏底，零副作用。
       */
      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(this.theme.secondary)
        .opacity(AppTheme.READER_RULE_ALPHA)
        .position({ left: 0, right: 0, bottom: 0 })
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
  }
}
