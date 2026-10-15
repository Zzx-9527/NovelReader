import { ReaderSettings } from '../../model/ReaderSettings';
import { PageCache } from '../../model/PageCache';
import { LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';

/**
 * 汉字的实际宽度与字号之比。
 *
 * 实测校准值：391vp 容器 + 18 字号下，真实每行约 23 字
 * （`391 / 23 ≈ 17`，而字号是 18 ⇒ 比值约 0.94；取 0.92 略保守）。
 *
 * 这个值直接决定"每页能放多少字"：偏大 → 每行少算字 → 页面填不满；
 * 偏小 → 每行多算字 → 末行被裁掉。**改动它必须同步 ALGO_VERSION。**
 */
const CJK_WIDTH_RATIO: number = 0.92;

/**
 * 分页计算服务（纯计算，不碰数据库、不碰 UI）。
 *
 * 设计约束：
 *  - 断点是【章内 UTF-16 下标】，与 annotation 的偏移口径一致；
 *  - 页码不是稳定量：布局参数一变，断点全变，所以缓存用 layoutKey 区分；
 *  - 这里用"估算行容量"的方式装箱，而不是测量每个字形的实际宽度 ——
 *    测量需要真实容器尺寸与字体度量，属于 View 层；服务层保持可测。
 *    ViewModel 拿到容器宽高后调用 computeBreaks 即可。
 */
export class PaginationService {
  /**
   * 分页算法版本号 —— **改了断点算法就必须 +1**。
   *
   * ⚠️ 为什么必须有它：`layoutKey` 只描述"排版参数"，不含算法本身。
   * 改了 `computeBreaks` 的装箱逻辑而 key 不变时，旧断点仍会被缓存命中，
   * 表现是"代码明明改了、跑起来还是老样子"（本项目实测踩过：
   * 修完段间距算法后第一次运行仍是 `cache=HIT`，跑的还是旧结果）。
   *
   * 这与 §4.5 `SCHEMA_BUILD` 是同一类规矩：**算法/结构变了，指纹必须跟着变**。
   */
  private static readonly ALGO_VERSION: number = 11;

  /**
   * 实测分页允许处理的**正文字符数上限**。
   *
   * ⚠️ 为什么必须有这个上限（本项目实测的"白屏假死"根因）：
   * 实测分页的代价是"每页约 12 次 `measureTextSize` 系统调用"。
   * 正常章节几千字 ⇒ 十几次调用，可以接受；
   * 但**分章失败**（典型成因是编码选错）产生的"章"可达几十万字，
   * 一本几 MB 的书被切成个位数章，每章几十万~上百万字符。
   * 按 600 字/页算，一本 100 万字的书 = 1600 页 × 12 次 = **近 2 万次同步测量**，
   * 全部压在主线程上 —— 系统判定应用无响应，
   * 用户看到的就是"正文闪一下然后卡死"（首帧提交后就被排版压死）。
   *
   * 超过上限时**降级为估算分页**（`computeBreaks`）：
   * 估算版有已知的精度缺陷（页尾留白、偶尔裁行），
   * 但它 O(n) 且不调用任何系统 API —— 对"本来就不正常的书"来说，
   * **能翻页**远比"每页排得完美"重要。
   *
   * 取 6 万：正常网文单章 2000~5000 字，即使按"一卷一章"的排版，
   * 6 万字/章也远超常见量级 —— 不会误伤正常书，
   * 又能把测量次数控制在 100 页 × 12 ≈ 1200 次（约 0.5 秒）。
   */
  private static readonly MAX_MEASURED_CHARS: number = 60000;

  /**
   * 一页**最多**可能容纳的字符数（二分探测的上界）。
   *
   * ⚠️ 它的作用是限制单次 `measureTextSize` 处理多长的字符串。
   * 用 `text.length - offset` 当上界时，二分的第一次探测会把
   * "半个剩余章节"丢给系统测量 —— 大章就此假死（详见 `computeBreaksMeasured`）。
   *
   * 一屏几十行、每行几十字，实际容量在几百到一千多字；
   * 取 4000 是几倍余量，保证不会把本该一页的内容硬切成两页。
   */
  private static readonly MAX_CHARS_PER_PAGE: number = 4000;

  /**
   * 布局指纹：改字号/字体/行距/边距/容器尺寸都会得到不同的 key。
   *
   * 用可读字符串而不是哈希：
   *  - 单条缓存行几百字节，存储压力可忽略；
   *  - 出问题时能直接在 DB 里看出这条缓存的排版参数，便于排查。
   *
   * ⚠️ `firstPageExtraHeight` 也必须进指纹：同一个容器尺寸下，
   * "首页多了章节标题"与"首页没有标题"得到的是**不同的断点数组**，
   * 共用 key 会让两者互相覆盖。
   */
  static buildLayoutKey(settings: ReaderSettings, contentWidth: number, contentHeight: number,
    firstPageExtraHeight: number = 0): string {
    const w: number = Math.round(contentWidth);
    const h: number = Math.round(contentHeight);
    const hx: number = Math.round(Math.max(0, firstPageExtraHeight));
    // 版本号放在最前面：一眼就能看出这条缓存是哪版算法算的
    //
    // ⚠️ 凡是**参与 `computeBreaks` 计算**的排版参数都必须进 key，
    // 否则改了它却命中旧缓存 ⇒ "改了没反应"。
    // `pm`（页边距）是后补的：它决定可用宽度、直接影响每行字数。
    //
    // ⚠️ 字体进 key 用**解析后**的名字（`resolveFontFamily`），不用原始值：
    // `'system'`、`''` 与 `'HarmonyOS Sans'` 指的是**同一个字体**，
    // 用原始值会算出三个不同的 key、把同一份断点缓存三遍
    // （切字体时白算两次，还多占缓存）。
    const fontFamily: string = ReaderSettings.resolveFontFamily(settings.fontFamily);
    return `v${PaginationService.ALGO_VERSION}_w${w}_h${h}_hx${hx}`
      + `_fs${settings.fontSize}_lh${settings.lineHeight}_`
      + `ps${settings.paragraphSpacing}_ls${settings.letterSpacing}_`
      + `pm${settings.pageMargin}_`
      + `fi${settings.firstLineIndent}_ff${fontFamily}`;
  }

  /**
   * 这一章是否**太大、不能用实测分页**。
   *
   * 由 ViewModel 在选路前调用：超限时走 `computeBreaks`（估算），
   * 否则走 `computeBreaksMeasured`（实测）。判定收在这里，
   * 避免调用方各自写一个阈值比较（设计文档第 28 条）。
   */
  static isTooLargeForMeasured(text: string): boolean {
    return text.length > PaginationService.MAX_MEASURED_CHARS;
  }

  /**
   * **实测分页**：把"剩余文本"整段丢给系统量高度，二分出这一页能放多少字。
   *
   * 这是本项目分页的最终形态，替换掉之前所有"估算每行多少字"的做法。
   *
   * 为什么之前一直修不对（值得记下来）：
   * 估算式分页依赖一串近似系数 —— 汉字宽度比、标点宽度、缩进占位、
   * 段距折算行数……每本书、每种字号都要重新校准，而且**永远校准不完**。
   * 实测反复出现"算法以为排满 26 行、实际只渲染 19 行"。
   * 根因是它从没真正量过文字，全靠推。
   *
   * 这一版直接问系统："这段文字在这个宽度下占多高？"
   * 于是不需要任何宽度系数，也不需要猜折行位置 ——
   * 折行、行高、字距、缩进全部由系统按**与渲染完全相同的规则**算出来。
   *
   * @param text              该章正文（章内下标以它为准）
   * @param measure           测量回调：`(文本, 可用宽度, 本段是否从段落中间开始) => 高度(vp)`。
   *                          ⚠️ 第三个参数不是装饰：渲染前会给段首补缩进字符，
   *                          测量必须按**装饰后**的文本来量，否则量出的高度
   *                          比实际渲染的小，页面会溢出（见 `buildPagination` 的包装）。
   *                          页面只提供原始测量能力（它才拿得到 `UIContext`），
   *                          装饰与单位换算由 ViewModel 包装。
   * @param contentWidth      正文可用宽度（vp）
   * @param contentHeight     正文可用高度（vp）
   * @param firstPageExtraHeight 首页被章节标题占掉的高度（vp）
   */
  static computeBreaksMeasured(
    text: string,
    measure: (segment: string, width: number, startsMidParagraph: boolean) => number,
    contentWidth: number,
    contentHeight: number,
    firstPageExtraHeight: number = 0
  ): number[] {
    const breaks: number[] = [0];
    if (text.length === 0 || contentHeight <= 0 || contentWidth <= 0) {
      return breaks;
    }

    let offset: number = 0;
    let pageHeight: number = Math.max(1, contentHeight - Math.max(0, firstPageExtraHeight));

    while (offset < text.length) {
      /**
       * 本页是否从段落中间开始 —— 决定"页首那行要不要补缩进"。
       * 判据与渲染端 `renderAt` 完全一致：前一字符不是换行就说明是续排。
       */
      const startsMid: boolean = offset > 0 && text.charAt(offset - 1) !== '\n';

      /**
       * 二分：找出 `text[offset..]` 里"在这一页高度内放得下的最长前缀"。
       *
       * 用二分而不是逐字试：一页约 500 字，逐字要 500 次测量；
       * 二分只要 ~9 次。测量是系统调用，差两个数量级。
       *
       * ⚠️ 二分的单调性假设是"文字越多越高"。它在**绝大多数情况**成立；
       * 极端情况下（折行边界）可能有 ±1 字的抖动，肉眼不可见。
       *
       * ⚠️ **上界必须夹到"一页装得下的字数"**，不能用 `text.length - offset`。
       *
       * 这是"大章分页卡死"的关键：二分第一次探测的是**整个区间的一半** ——
       * 对 10 万字的章，第一次就把一个 5 万字的字符串交给
       * `measureTextSize`（且测量前还要先把这 5 万字跑一遍缩进装饰），
       * 单次调用就要几百毫秒；整章累计下来是几十秒的假死。
       * 而"一页能放多少字"是有物理上限的（一屏几十行 × 每行几十字），
       * 夹住上界之后每次测量都只处理几千字，快两个数量级。
       *
       * 取 4000：默认排版一页约 600 字，即使小字号 + 大屏也远到不了 4000，
       * 留了足够余量，不会把"能放更多字"的页误切成两页。
       */
      let lo: number = 1;
      let hi: number = Math.min(text.length - offset, PaginationService.MAX_CHARS_PER_PAGE);
      let best: number = 0;
      while (lo <= hi) {
        const mid: number = Math.floor((lo + hi) / 2);
        const h: number = measure(text.substring(offset, offset + mid), contentWidth, startsMid);
        if (h <= pageHeight) {
          best = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      if (best <= 0) {
        // 连一个字都放不下（高度异常小）→ 至少推进一个字，避免死循环
        best = 1;
      }
      /**
       * ⚠️ 别让下一页从**换行符**开始。
       *
       * 二分找到的前缀可能恰好停在行末（不含那个 `\n`），
       * 于是下一页以 `\n` 开头 —— 渲染出来就是**页面顶部凭空多一个空行**。
       * 这正是用户反馈的"有时候顶部空了一行"：只有切页点刚好落在
       * 换行之前时才会出现，所以是**间歇性**的。
       *
       * 处理：如果下一个字符是 `\n`，试着把它一起收进本页。
       * 换行符跟在行尾几乎不额外占高，通常都能收下；
       * 万一收不下，由下面的"跳过页首换行"兜底。
       */
      const nextIdx: number = offset + best;
      if (nextIdx < text.length && text.charAt(nextIdx) === '\n') {
        const withNl: number = measure(
          text.substring(offset, nextIdx + 1), contentWidth, startsMid);
        if (withNl <= pageHeight) {
          best += 1;
        }
      }
      offset += best;
      /**
       * ⚠️ 跳过页首的换行符，别让新页以空白开头。
       *
       * 换行符在页边界处**没有意义**：它本来只表示"上一行结束"，
       * 而页边界已经承担了这个语义。留着它，渲染出来就是
       * **页面顶部凭空多一个空行**（用户反馈的"有时候顶部空了一行"）。
       *
       * 这些字符不属于任何一页（页边界把它们吸收了），
       * 因此不会影响断点偏移的正确性 —— `breaks` 里存的仍是原文下标。
       */
      while (offset < text.length && text.charAt(offset) === '\n') {
        offset += 1;
      }
      if (offset < text.length) {
        breaks.push(offset);
      }
      // 首页之后都是标准容量
      pageHeight = contentHeight;
    }
    return breaks;
  }

  /**
   * 计算分页断点（**估算版，已被 `computeBreaksMeasured` 取代**）。
   *
   * 保留它只作参考与降级：万一页面拿不到 `UIContext`（理论上不会），
   * 或测量调用异常，仍有一条能出页面的路。
   * 新代码请用 `computeBreaksMeasured`。
   *
   * @param text                  该章正文（章内下标以它为准）
   * @param settings              阅读设置
   * @param contentWidth          正文区宽度（vp）
   * @param contentHeight         正文区高度（vp）
   * @param firstPageExtraHeight  第一页被"章节标题"占掉的高度（vp），0 表示首页无标题
   * @returns 断点数组，breaks[0] === 0；第 i 页覆盖 [breaks[i], breaks[i+1])
   */
  static computeBreaks(
    text: string, settings: ReaderSettings, contentWidth: number, contentHeight: number,
    firstPageExtraHeight: number = 0
  ): number[] {
    const breaks: number[] = [0];
    if (text.length === 0) {
      return breaks;
    }

    const lineHeight: number = settings.fontSize * settings.lineHeight;
    const linesPerPage: number = Math.max(1, Math.floor(contentHeight / Math.max(1, lineHeight)));
    // 首页要给章节标题让位：容量可能比后续页少若干行
    const firstPageLines: number = Math.max(1,
      Math.floor((contentHeight - Math.max(0, firstPageExtraHeight)) / Math.max(1, lineHeight)));
    // 每行可容纳的字符数。
    //
    // ⚠️ 不是 `contentWidth / fontSize` —— 那等于假设"每个汉字宽度 = 字号"，
    // 而实际上：汉字宽约 0.92 字号、中文标点约 0.5 字号、数字/字母更窄。
    // 本项目实测校准：391vp 宽 / 18 字号下，真实每行约 23 字，
    // 而 `391/18 = 21`（每行少算 2 字，一页 26 行就少算 52 字 ⇒ 页面填不满）。
    // 系数 0.92 是"汉字为主、夹杂标点"的正文的合理近似。
    //
    // 字间距（letterSpacing）必须加进"每个字的占宽"里：
    // 它让每个字多占 `letterSpacing` 个 vp，字距调大后每行能放的字会明显变少
    // （比如 18 字号 + 4 字距，每字占宽从 16.6 变 20.6，一行少放约 4 个字）。
    // 不算它的话，用户一调字距就会溢出屏幕、末行被裁。
    //
    // 页边距（pageMargin）左右各占一份，可用宽度要减掉。
    const usableWidth: number = Math.max(1,
      contentWidth - Math.max(0, settings.pageMargin) * 2);
    const charWidth: number = Math.max(1,
      settings.fontSize * CJK_WIDTH_RATIO + Math.max(0, settings.letterSpacing));
    const charsPerLine: number = Math.max(1, Math.floor(usableWidth / charWidth));
    // 段落前后的空行（用段距折算成行）
    const spacingLines: number = Math.max(0, Math.round(settings.paragraphSpacing * 2));

    let lineCount: number = 0;
    /**
     * 是否还在填**第一页**（首页容量可能更小，因为顶端要给章节标题让位）。
     *
     * ⚠️ 不能用 `breaks.length === 1` 代替这个标志：
     * `startNewPage` 里有"同一起点不重复 push"的去重逻辑，
     * 一旦第一页切出的起点与 0 重合，`breaks.length` 会停在 1，
     * 于是**每一页都被当成首页**按小容量装箱，整本书每页都比实际能放的字少。
     */
    let fillingFirstPage: boolean = true;

    // 当前正在填充的那一页能放几行
    const capacity = (): number => {
      return fillingFirstPage ? firstPageLines : linesPerPage;
    };

    const startNewPage = (offset: number): void => {
      // 连续两页同一起点没有意义，避免产生空页
      if (breaks[breaks.length - 1] !== offset) {
        breaks.push(offset);
      }
      // 一旦要求换页，后面填的就不再是首页了（无论上面有没有真的 push）
      fillingFirstPage = false;
      lineCount = 0;
    };

    // 按行切分（\n），保留空行占位
    let lineStart: number = 0;
    /**
     * 上一行是否"开着"一个段落（即上一行非空）。
     *
     * ⚠️ 这是段间距算法的关键：TXT 里一个自然段常被**硬换行成多个物理行**，
     * 段间距只能加在**段落之间**，绝不能每个物理行都加一次。
     * 初版没区分这两者，于是"13 个物理行的一段"被算成 `13 × (1+1) = 26` 行，
     * 而实际渲染只占 13 行 —— 表现就是"每页只切很少的字、屏幕大半是空白"
     * （分页以为排满了，其实只用了半屏）。
     *
     * 判据用**空行**作为段落分隔：这是 TXT 最可靠的信号，
     * 比"上一行是否以标点结尾"这类启发式稳得多（后者在对话、列表上会误判）。
     */
    let prevLineOpen: boolean = false;
    /**
     * 上一行是否是纯空白行。
     *
     * ⚠️ 它决定"要不要再补段间距"：**原文已经用空行表达过段间距了，
     * 就不能再叠加设置里的 paragraphSpacing**。
     *
     * 本项目实测根因：这本 TXT 每段之间本就有空行（渲染时占 1 行），
     * 而算法又按 `paragraphSpacing` 每段补 1 行 ⇒ 每段凭空多算 1 行。
     * 图 1 有 8 段，26 − 8 = 18 行，与实测"屏幕只放得下 19 行"几乎完全吻合 ⇒
     * 算法以为排满了 26 行，其实只用了 18 行，底部于是空一大块。
     *
     * 正确语义：**原文有间距就用原文的，原文没有才用设置补**。
     */
    let prevLineBlank: boolean = false;
    /**
     * 诊断计数器：记录前若干个物理行的"行数账"。
     *
     * 分页不准时最难查的就是"到底哪一步把行数算多了"，
     * 这里把每行的 `字数/估算行数/是否起新段/累计行数/当前容量` 全记下来，
     * 跑一次就能看出是容量算错还是行数算错。
     */
    let diagLines: number = 0;
    const diag: string[] = [];
    while (lineStart <= text.length) {
      const nlIndex: number = text.indexOf('\n', lineStart);
      const isLast: boolean = nlIndex < 0;
      const lineEnd: number = isLast ? text.length : nlIndex;
      const lineText: string = text.substring(lineStart, lineEnd);

      const isBlank: boolean = PaginationService.isBlankLine(lineText);
      /**
       * 纯空白行**占 1 行**（它渲染出来就是一行空白），但**不额外补段距**。
       *
       * ⚠️ 这里纠正过一次判断：曾把空白行算成 0 行，理由是"伪行几乎不占高"。
       * 但那与渲染事实不符 —— `Text` 里一个 `\n` 就是实打实的一次换行，
       * 空白行在屏幕上占满一整行。算法少算它，就会以为还能多放，
       * 结果切给这一页的字超出屏幕、末尾被裁。
       *
       * 现在两侧一致：**空白行 = 1 行，且它就是段间距本身**，
       * 于是 `paragraphSpacing` 只在"原文没有空行"时才补（见 `needsSpacing`）。
       */
      const wrappedLines: number = isBlank
        ? 1
        : Math.max(1, Math.ceil(lineText.length / charsPerLine));
      // 新段落的起点 = 本行有内容、且上一行**没有**开着段落。
      // 空白行自己不开段落，因此它前后的两段会被正确识别为两个段首。
      const startsNewParagraph: boolean = !isBlank && !prevLineOpen;
      /**
       * 是否要为本段补"设置里的段间距"。
       *
       * ⚠️ **原文自带空行时不再补** —— 见 `prevLineBlank` 的说明。
       * 这是"每页填不满"的直接原因：每段多算 1 行，8 段就少放 8 行。
       */
      const needsSpacing: boolean = startsNewParagraph && !prevLineBlank;

      if (diagLines < 14) {
        // 把首字符码点也打出来：本项目实测遇到过"字=1 却看不见"的行，
        // 那是全角空格 U+3000（`trim()` **不**认为它是空白）。
        // 有码点，下次冒出别的隐形字符就不用再猜。
        const code: string = lineText.length > 0
          ? `0x${lineText.charCodeAt(0).toString(16)}`
          : '-';
        diag.push(`[#${diagLines} 字=${lineText.length}${isBlank ? '(空)' : ''}`
          + ` 码=${code} 视觉行=${wrappedLines}`
          + `${needsSpacing ? '+段距' : ''}`
          + ` 入页前行数=${lineCount} 容量=${capacity()}]`);
        diagLines++;
      }

      // ── 逐"视觉行"装箱 ────────────────────────────────────────────
      //
      // ⚠️ 这里从"按段落整体装箱"改成了"按视觉行装箱"，是本项目分页的
      // **模型级修正**（用户实测反馈驱动）：
      //
      // 旧模型把每个物理行当成不可分割的单位，放不下就整行（甚至整段）
      // 推到下一页。后果：一段有 3 行、而当前页只剩 1 行时，整段被推走，
      // 当前页底部空 2 行 —— 长段落多的书，底部会留出大块空白。
      //
      // 正确的语义（也是所有正经阅读器的做法）：
      //   把段落按"每行可容纳字数"切成视觉行，**逐视觉行**往当前页放，
      //   放不下就在**该视觉行的字符位置**切页。
      //   于是同一段文字可以横跨两页 —— 页与页之间是"字符偏移"的切分，
      //   而不是"段落边界"的切分，每页也因此能真正填满。
      //
      // 段间距（spacingLines）作为"额外的空行"参与同一套装箱，
      // 它同样可以在页边界处被切开 —— 这正是"填满"的必要条件。

      // 段首前要插入的空行数（只在"原文没自带间距"时非 0）
      let pendingSpacing: number = needsSpacing ? spacingLines : 0;

      // 先消化段距：它本身也可能跨页
      while (pendingSpacing > 0) {
        if (lineCount + 1 > capacity()) {
          // 当前页已满：段距留在下一页头顶，切页点就是本行的起点
          startNewPage(lineStart);
        }
        lineCount += 1;
        pendingSpacing -= 1;
      }

      if (isBlank) {
        // 空白行：渲染时占满 1 行，这里也必须算 1 行（两侧口径一致）。
        // 它同样是"可被页边界切开"的单位 —— 放不下就整体挪到下一页，
        // 不能让它悬在页尾把正文挤出去。
        if (lineCount + 1 > capacity()) {
          startNewPage(lineStart);
        }
        lineCount += 1;
      } else if (lineText.length > 0) {
        // 把本行按 charsPerLine 切成若干视觉行，逐行放入当前页。
        //
        // ⚠️ 循环条件是"还有没放完的字"（`charCursor < lineText.length`），
        // **不是**"还剩几行" —— 后者一旦与真实字数不同步（估算偏差），
        // 就会把 `charCursor` 推过行尾，切页点落到下一行去，造成偏移错位。
        // 用字数当循环条件，切页点天然落在 [lineStart, lineEnd) 之内。
        let charCursor: number = 0;
        while (charCursor < lineText.length) {
          if (lineCount + 1 > capacity()) {
            // 本视觉行放不下 → 在**当前字符位置**切页（不是段落边界！）
            // 这正是"同一段可以横跨两页"的实现点：
            // 上一页末尾停在此处，下一页从同一个字符继续。
            startNewPage(lineStart + charCursor);
          }
          /**
           * 本视觉行能放多少字。
           *
           * ⚠️ **段首的第一个视觉行要再减掉缩进占位**：
           * 段落首行会缩进 `firstLineIndent` 个字，可用宽度少了那么多，
           * 能放的字自然也少。不减的话这一行会多放 2 个字 ⇒ 折成两行 ⇒
           * 整页比算法预期的多占一行 ⇒ 末行被裁。
           *
           * 判断"是不是段首的第一个视觉行"用 `charCursor === 0`：
           * 只有本段开头那一次才享受/承受缩进。
           */
          const isParagraphFirstLine: boolean = startsNewParagraph && charCursor === 0;
          const availChars: number = isParagraphFirstLine
            ? Math.max(1, charsPerLine - Math.max(0, Math.round(settings.firstLineIndent)))
            : charsPerLine;
          // 本视觉行推进多少字：最后一行的余数可能不满一行
          const remainChars: number = lineText.length - charCursor;
          const take: number = Math.min(availChars, remainChars);
          charCursor += take;
          lineCount += 1;
        }
      }

      prevLineOpen = !isBlank;
      prevLineBlank = isBlank;
      if (isLast) {
        break;
      }
      lineStart = nlIndex + 1;
    }

    // 把"收到的尺寸 + 容量参数 + 前 14 行的行数账 + 切页结果"一次打完。
    // 排查分页不准时看这一条就够了：参数对不对、行数怎么累的、在哪断的。
    // 收到的 w/h 要和页面打的"分页尺寸"逐位对上 —— 对不上就是传参错了。
    Logger.info(LogTag.PAGINATION,
      `分页算账: 收到w=${contentWidth.toFixed(1)} h=${contentHeight.toFixed(1)}`
        + ` 首页让位=${firstPageExtraHeight.toFixed(1)}`
        + ` | 行高=${lineHeight.toFixed(1)} 每页行数=${linesPerPage}`
        + ` 首页行数=${firstPageLines} 每行字数=${charsPerLine} 段距行数=${spacingLines}`
        + ` | 正文长度=${text.length} 页数=${breaks.length}`
        + ` 首页字数=${breaks.length > 1 ? breaks[1] - breaks[0] : -1}`);
    Logger.info(LogTag.PAGINATION, `分页逐行: ${diag.join(' ')}`);
    return breaks;
  }

  /**
   * 判断一行是不是"视觉上的空行"。
   *
   * ⚠️ 不能用 `line.trim().length === 0`：**`trim()` 不认全角空格 U+3000**
   * （它只按 Unicode 的 White_Space 属性处理，而 U+3000 虽然是空白，
   * 但 `\u00A0`、`\u2000`~`\u200A`、`\u3000` 这类在 JS 里表现并不一致）。
   *
   * 本项目实测踩过：这本 TXT 每段前后有单独一行的全角空格，
   * 被当成"1 个字的正文行" → 每段多算 1 行、并额外触发一次段距，
   * 13 个物理行被算成 26 行（实际只渲染 19 行）⇒
   * "每页只切一半的字、屏幕下半截全空"。
   */
  private static isBlankLine(line: string): boolean {
    for (let i = 0; i < line.length; i++) {
      const c: number = line.charCodeAt(i);
      // 常见空白：普通空格、\t、\r、\n、全角空格、不换行空格
      const isSpace: boolean = c === 0x20 || c === 0x09 || c === 0x0D || c === 0x0A
        || c === 0x3000 || c === 0x00A0 || c === 0x2007 || c === 0x202F
        // Unicode 通用空白区（EN QUAD ~ HAIR SPACE）
        || (c >= 0x2000 && c <= 0x200A)
        // 零宽字符：视觉上不存在，也不该占一行
        || c === 0x200B || c === 0xFEFF;
      if (!isSpace) {
        return false;
      }
    }
    return true;
  }

  /**
   * 根据章内偏移求页码（0-based）。
   * 委托给 PageCache.locatePage，保证全项目只有一处二分实现。
   */
  static locatePage(breaks: number[], offset: number): number {
    return PageCache.locatePage(breaks, offset);
  }

  /** 该偏移所在页的起始下标，用于跳转后定位渲染起点 */
  static pageStartOffset(breaks: number[], offset: number): number {
    const page: number = PaginationService.locatePage(breaks, offset);
    return breaks.length > page ? breaks[page] : 0;
  }

  static pageCount(breaks: number[]): number {
    return breaks.length;
  }
}
