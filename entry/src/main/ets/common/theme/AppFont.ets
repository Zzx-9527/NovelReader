import { UIContext } from '@kit.ArkUI';

/**
 * UI 字体与数字形态的**唯一来源**。
 *
 * ## 为什么需要这一层
 *
 * 设计文档反复强调的"同一逻辑两处实现，改一处必忘另一处"（第 28 条）——
 * 字体族名与数字特性都属于这一类：书名、章节标题、章节名、页码、统计数值
 * 一共十几处，若各自写一个字面量，将来要调整就得满项目找。
 *
 * ## 关于衬线字体：本项目**不使用**，这里说清为什么
 *
 * 曾评估过给标题配中文衬线（宋体/思源宋体），结论是**不做**。
 * 依据是查本机 SDK 声明文件得到的两条事实：
 *
 * 1. `text.d.ts` 对 `fontFamily` 的说明：
 *    > Default font: 'HarmonyOS Sans'
 *    > The 'HarmonyOS Sans' font and **registered custom fonts** are supported for applications.
 * 2. `@ohos.arkui.UIContext.d.ts` 对 `getSystemFontList()` 的说明：
 *    > **This API takes effect only on 2-in-1 devices.**
 *
 * 两条合起来：**手机上拿不到任何"未注册"的中文衬线**，唯一的路是用
 * `registerFont` 往包里塞一个字体文件。而中文衬线（思源宋体一类）
 * 动辄 10~20 MB —— 本项目的标题只用到几十个不同的字，
 * 为了这几十个字背 20 MB 字库，与"完全离线、轻量、零图片依赖"的定位
 * 不相称。**所以刻意不引入字体资源。**
 *
 * 那"书卷气"从哪来？—— **字距 + 字重 + 题花线**：
 * 见 `AppTheme.TRACK_*` 那组常量，以及封面上的题花短线、章节标题下的题花线。
 * 这三样与字体、设备、系统版本全部无关，是**确定性**的收益 ——
 * 比押在一个"某些设备上才生效"的字体上更可靠。
 *
 * ⚠️ `probe()` 仍然保留：2-in-1 设备（平板/PC）上系统可能自带衬线，
 * 探到就顺手用上，探不到就回退，**零成本**。
 * 它只是"有则更好"，不是设计的依赖项。
 */
export class AppFont {
  /** 系统默认字体族名。与 `ReaderSettings.SYSTEM_FONT` 同值、同口径 */
  static readonly SYSTEM: string = 'HarmonyOS Sans';

  /**
   * 探测顺序：从最可能自带的中文衬线开始。
   *
   * ⚠️ 顺序即优先级，第一个命中就停。名字必须**逐字精确**（不分大小写）——
   * 写成近似的名字等于探测永远失败，而失败是静默的（回退到无衬线，不报错）。
   */
  static readonly SERIF_CANDIDATES: string[] = [
    'Source Han Serif SC',
    'Noto Serif SC',
    'Noto Serif CJK SC',
    'Source Han Serif CN'
  ];

  /**
   * 系统探测结果：空串 = 系统没有自带衬线（**这是手机的常态**）。
   */
  private static serifFamily: string = '';

  /**
   * 探测系统自带的衬线字体。由 `EntryAbility.onWindowStageCreate` 调一次。
   *
   * ⚠️ 全程不抛异常：接口在手机上可能直接不可用（文档明说仅 2-in-1 生效），
   * 那种情况下 `getSystemFontList()` 返回空数组或抛错 —— 两者都按"没有衬线"处理。
   * **调用方不需要 try**，这是刻意的：字体是装饰，绝不该影响启动。
   *
   * ⚠️ 它只影响**标题类**文字（封面首字、书名、章节标题、wordmark、页面标题），
   * **不碰阅读正文** —— 正文的字体走 `ReaderSettings.resolveFontFamily()`，
   * 那里与分页测量同源，不允许被 UI 层的字体逻辑干扰。
   */
  static probe(uiContext: UIContext): void {
    if (AppFont.serifFamily.length > 0) {
      return;
    }
    try {
      const installed: string[] = uiContext.getFont().getSystemFontList();
      if (installed === undefined || installed.length === 0) {
        return;
      }
      for (const candidate of AppFont.SERIF_CANDIDATES) {
        for (const name of installed) {
          if (name.toLowerCase() === candidate.toLowerCase()) {
            // 用**系统报出来的原名**，不用候选名：两者大小写/写法可能不同
            AppFont.serifFamily = name;
            return;
          }
        }
      }
    } catch (e) {
      // 手机/平板：接口不可用。静默降级到系统字体，不写日志避免启动期噪音
    }
  }

  /**
   * 标题类文字（书名、章节标题、封面首字、wordmark、页面标题）的字体族。
   *
   * 优先级：**系统自带的衬线（若探到） > 系统无衬线**。
   *
   * ⚠️ 返回的**一定**是可直接传给 `Text.fontFamily()` 的确定名字：
   * 没探到就返回 `SYSTEM`，而不是空串 —— 空串在部分实现上会被当成
   * "未设置"而走另一条回退路径，那时**分页测量与渲染可能取到不同字体**
   * （正是 `ReaderSettings.resolveFontFamily` 注释里记的那个坑）。
   */
  static titleFamily(): string {
    return AppFont.serifFamily.length > 0 ? AppFont.serifFamily : AppFont.SYSTEM;
  }

  /**
   * 等宽数字（tabular figures）特性串。
   *
   * 用法：`.fontFeature(AppFont.TABULAR)`
   *
   * ⚠️ 存在的理由是一个真实的观感缺陷：页码 `5/16`、百分比 `97.1%`
   * 在比例数字下每位宽度不同，翻页时整行数字会**左右抖动**，
   * 常驻底栏那两段文字尤其明显。
   *
   * ⚠️ 格式来自 SDK：`<feature-tag-value> = <string> [ <integer> | on | off ]`，
   * 例如 `"ss01" 0`。所以 `tnum` 这个标签**必须带引号**。
   * 设备字体若无该特性，系统**忽略**此属性（不报错、不换字体），
   * 因此这是一条"支持则更好、不支持也无副作用"的增强。
   */
  static readonly TABULAR: string = '"tnum" 1';
}
