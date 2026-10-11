import { ReaderSettings } from '../../model/ReaderSettings';
import { PageCache } from '../../model/PageCache';

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
   * 布局指纹：改字号/字体/行距/边距/容器尺寸都会得到不同的 key。
   *
   * 用可读字符串而不是哈希：
   *  - 单条缓存行几百字节，存储压力可忽略；
   *  - 出问题时能直接在 DB 里看出这条缓存的排版参数，便于排查。
   */
  static buildLayoutKey(settings: ReaderSettings, contentWidth: number, contentHeight: number): string {
    const w: number = Math.round(contentWidth);
    const h: number = Math.round(contentHeight);
    return `w${w}_h${h}_fs${settings.fontSize}_lh${settings.lineHeight}_`
      + `ps${settings.paragraphSpacing}_ls${settings.letterSpacing}_`
      + `fi${settings.firstLineIndent}_ff${settings.fontFamily}`;
  }

  /**
   * 计算分页断点。
   *
   * @param text            该章正文（章内下标以它为准）
   * @param settings        阅读设置
   * @param contentWidth    正文区宽度（vp）
   * @param contentHeight   正文区高度（vp）
   * @returns 断点数组，breaks[0] === 0；第 i 页覆盖 [breaks[i], breaks[i+1])
   */
  static computeBreaks(
    text: string, settings: ReaderSettings, contentWidth: number, contentHeight: number
  ): number[] {
    const breaks: number[] = [0];
    if (text.length === 0) {
      return breaks;
    }

    const lineHeight: number = settings.fontSize * settings.lineHeight;
    const linesPerPage: number = Math.max(1, Math.floor(contentHeight / Math.max(1, lineHeight)));
    // 每行可容纳的字符数。中文按 1 个字宽、ASCII 约 0.5 估算，取下限保护。
    const charsPerLine: number = Math.max(1,
      Math.floor(contentWidth / Math.max(1, settings.fontSize)));
    // 段落前后的空行（用段距折算成行）
    const spacingLines: number = Math.max(0, Math.round(settings.paragraphSpacing * 2));

    let lineCount: number = 0;

    const startNewPage = (offset: number): void => {
      // 连续两页同一起点没有意义，避免产生空页
      if (breaks[breaks.length - 1] !== offset) {
        breaks.push(offset);
      }
      lineCount = 0;
    };

    // 按行切分（\n），保留空行占位
    let lineStart: number = 0;
    while (lineStart <= text.length) {
      const nlIndex: number = text.indexOf('\n', lineStart);
      const isLast: boolean = nlIndex < 0;
      const lineEnd: number = isLast ? text.length : nlIndex;
      const lineText: string = text.substring(lineStart, lineEnd);

      // 本段占用的行数：首行缩进会略微减少首行容量，这里忽略其影响
      const wrappedLines: number = lineText.length === 0
        ? 1
        : Math.max(1, Math.ceil(lineText.length / charsPerLine));
      const totalLines: number = wrappedLines + spacingLines;

      if (lineCount > 0 && lineCount + totalLines > linesPerPage) {
        startNewPage(lineStart);
      }

      if (totalLines >= linesPerPage) {
        // 单段就超过一页：按页切分，避免出现"永远放不下"的死循环
        let consumed: number = 0;
        let remainingLines: number = wrappedLines;
        while (remainingLines > linesPerPage) {
          consumed += linesPerPage * charsPerLine;
          remainingLines -= linesPerPage;
          startNewPage(lineStart + Math.min(consumed, lineText.length));
        }
        lineCount = remainingLines + spacingLines;
      } else {
        lineCount += totalLines;
      }

      if (isLast) {
        break;
      }
      lineStart = nlIndex + 1;
    }
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
