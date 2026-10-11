/**
 * 分页缓存（纯数据，纯派生：可随时清空）。
 *
 * breaks 是与正文一一对应的断点数组，元素为【章内 UTF-16 下标】。
 * 约定 breaks[0] === 0；第 i 页覆盖 [breaks[i], breaks[i+1])。
 */
export class PageCache {
  id: number = 0;
  bookId: number = 0;
  chapterIndex: number = 0;
  /** 排版方案指纹，由 PaginationService.buildLayoutKey 生成 */
  layoutKey: string = '';
  breaks: number[] = [];
  pageCount: number = 0;
  updatedAt: number = 0;

  /** 安全解析断点数组；任何异常都返回空数组（缓存坏了就重算，不能崩） */
  static breaksFromJson(raw: string): number[] {
    if (raw === undefined || raw === null || raw.length === 0) {
      return [];
    }
    try {
      const arr = JSON.parse(raw) as number[];
      if (arr === null || arr === undefined || arr.length === 0) {
        return [];
      }
      return arr;
    } catch (e) {
      return [];
    }
  }

  static breaksToJson(breaks: number[]): string {
    return JSON.stringify(breaks);
  }

  /**
   * 根据章内偏移求页码（0-based）。
   *
   * 用"最后一个 <= offset 的断点"定位，等价于 upper_bound(offset) - 1。
   * 不要写成"首个 breaks[i] > offset 的页" —— offset 恰好落在某页断点上时会多翻一页。
   */
  static locatePage(breaks: number[], offset: number): number {
    if (breaks.length === 0) {
      return 0;
    }
    let lo: number = 0;
    let hi: number = breaks.length;
    while (lo < hi) {
      const mid: number = Math.floor((lo + hi) / 2);
      if (breaks[mid] <= offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return Math.max(0, lo - 1);
  }
}
