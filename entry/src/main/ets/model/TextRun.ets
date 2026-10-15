/**
 * 正文的一段"文本片段"，用来把**划线**画到阅读页的正文上。
 *
 * ## 为什么需要它
 *
 * 正文原本是一整个 `Text(renderedText)` 字符串，划线虽然存进了库，
 * 却**没有任何机制把它画出来** —— 用户划了线、读的时候屏幕上什么都没有。
 *
 * 要画出底色，只能把正文拆成"普通段 / 高亮段"交替的片段，
 * 用 `Span` 包住高亮段并给它 `textBackgroundStyle`。
 *
 * ## 为什么用 `Span` 而不是 `StyledString`
 *
 * ⚠️ 这是一个**不能选错**的决定，理由是分页测量：
 *
 * 本项目分页用的是 `UIContext.getMeasureUtils().measureTextSize()`，
 * 而它的 `MeasureOptions.textContent` 类型是 `string | Resource` ——
 * **不接受 `StyledString`**（查 SDK `@ohos.measure.d.ts` 确认）。
 * 若改用 `TextController.setStyledString()` 上样式，**渲染走 styled 路径、
 * 测量仍走纯字符串路径**，两者立刻不同源 ——
 * 正是设计文档反复警告的"测量与渲染不同源"，后果是分页悄悄算错、
 * 末行被裁，而且不报错。
 *
 * 而 `Span` 是 `Text` 的**子节点**：字体、行高、字距、内外边距全部继承父
 * `Text`，父 `Text` 上那套测量口径原封不动。所以 `Span` 是唯一
 * 不破坏分页的选项。
 *
 * ⚠️ 本类只描述"哪一段该有底色"，**不含任何渲染逻辑**：
 * 分页模式与滚动模式各渲染一次，但用的是同一份分段结果。
 */
export class TextRun {
  /** 这一段的文字（渲染后文本的连续切片，拼接起来必须等于整段文本） */
  text: string = '';
  /**
   * 是否落在某个划线的区间内。
   *
   * ⚠️ 只有**划线**（`ANNOTATION_HIGHLIGHT`）会置 true。
   * 书签与笔记不进正文：书签是"一个位置"不是"一段范围"，
   * 笔记的正文是用户写的备注、在段落里没有落脚处（它们在目录页的
   * 「书签 / 笔记」两个 Tab 里看）。给它们上底色只会让正文变成花脸，
   * 而且用户分不清"这段是划线还是笔记"。
   */
  highlighted: boolean = false;

  constructor(text: string, highlighted: boolean) {
    this.text = text;
    this.highlighted = highlighted;
  }
}
