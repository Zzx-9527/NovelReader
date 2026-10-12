import { ReaderSettings } from '../../model/ReaderSettings';
import { PageCache } from '../../model/PageCache';
import { LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';

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
  private static readonly ALGO_VERSION: number = 3;

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
    return `v${PaginationService.ALGO_VERSION}_w${w}_h${h}_hx${hx}`
      + `_fs${settings.fontSize}_lh${settings.lineHeight}_`
      + `ps${settings.paragraphSpacing}_ls${settings.letterSpacing}_`
      + `fi${settings.firstLineIndent}_ff${settings.fontFamily}`;
  }

  /**
   * 计算分页断点。
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
    // 每行可容纳的字符数。中文按 1 个字宽、ASCII 约 0.5 估算，取下限保护。
    const charsPerLine: number = Math.max(1,
      Math.floor(contentWidth / Math.max(1, settings.fontSize)));
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

      const isBlank: boolean = lineText.trim().length === 0;
      // 本行占用的行数：首行缩进会略微减少首行容量，这里忽略其影响
      const wrappedLines: number = isBlank
        ? 1
        : Math.max(1, Math.ceil(lineText.length / charsPerLine));
      // 段间距只加在"真正新起一个段落"的那一行：
      // 空行本身已占 1 行，不再额外加间距（否则空行会变成 2 行高）。
      const startsNewParagraph: boolean = !isBlank && !prevLineOpen;
      const totalLines: number = wrappedLines
        + (startsNewParagraph ? spacingLines : 0);

      if (diagLines < 14) {
        diag.push(`[#${diagLines} 字=${lineText.length} 行=${wrappedLines}`
          + `${startsNewParagraph ? '+段距' : ''}=${totalLines}`
          + ` 累计=${lineCount}->${lineCount + totalLines} 容量=${capacity()}]`);
        diagLines++;
      }

      if (lineCount > 0 && lineCount + totalLines > capacity()) {
        startNewPage(lineStart);
      }

      if (totalLines >= capacity()) {
        // 单行就超过一页：按页切分，避免出现"永远放不下"的死循环
        let consumed: number = 0;
        let remainingLines: number = wrappedLines;
        // 首页容量可能更小，先按当前页容量切一刀，之后都按标准容量
        let cap: number = capacity();
        while (remainingLines > cap) {
          consumed += cap * charsPerLine;
          remainingLines -= cap;
          startNewPage(lineStart + Math.min(consumed, lineText.length));
          cap = linesPerPage;
        }
        lineCount = remainingLines + (startsNewParagraph ? spacingLines : 0);
      } else {
        lineCount += totalLines;
      }

      prevLineOpen = !isBlank;
      if (isLast) {
        break;
      }
      lineStart = nlIndex + 1;
    }

    // 把"容量参数 + 前 14 行的行数账 + 切页结果"一次打完。
    // 排查分页不准时看这一条就够了：容量对不对、行数怎么累的、在哪断的。
    Logger.info(LogTag.PAGINATION,
      `分页算账: 行高=${lineHeight.toFixed(1)} 每页行数=${linesPerPage}`
        + ` 首页行数=${firstPageLines} 每行字数=${charsPerLine} 段距行数=${spacingLines}`
        + ` 正文长度=${text.length} 页数=${breaks.length}`
        + ` 首页字数=${breaks.length > 1 ? breaks[1] - breaks[0] : -1}`);
    Logger.info(LogTag.PAGINATION, `分页逐行: ${diag.join(' ')}`);
    return breaks;
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
