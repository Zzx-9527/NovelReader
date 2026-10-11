import { AppConstants } from '../../common/constants/AppConstants';

/** 缓存条目 */
class CacheEntry {
  key: string = '';
  text: string = '';
  /** 该条目的字符数，用于按内存限额淘汰 */
  chars: number = 0;
}

/**
 * 章节正文 LRU 缓存。
 *
 * 为什么不用 Map：ArkTS 对跨模块集合类型的支持有不确定性，
 * 缓存条目很少，用数组最简单可靠。
 *
 * 两条硬约束：
 *  1. **key 必须含 bookId** —— 否则换书（尤其是"换编码重新解析"之后重建服务）时
 *     旧内容会被新书命中，读出完全错误的章节；
 *  2. **必须有内存上限** —— 单章上限 2 MiB，若只按条数限制 5 条，
 *     最坏会驻留 10 MB 的字符串（UTF-16 下约 20 MB），足以把 11 MB 的 TXT 读崩。
 *     这里改成按字符数限额，超了就淘汰最旧的。
 */
export class ChapterCache {
  private entries: CacheEntry[] = [];
  private totalChars: number = 0;

  /** 内存限额（字符数）：约 1.5 MB 字符串 */
  private static readonly MAX_CHARS: number = 1_500_000;
  /** 条数上限（双保险） */
  private static readonly MAX_ENTRIES: number = AppConstants.CHAPTER_CACHE_SIZE;

  get(key: string): string | null {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === key) {
        const entry: CacheEntry = this.entries[i];
        // 命中后移到末尾（最近使用）
        this.entries.splice(i, 1);
        this.entries.push(entry);
        return entry.text;
      }
    }
    return null;
  }

  put(key: string, value: string): void {
    // 单条就超过总限额的 1/3：不缓存，避免一次放入就挤空全部
    if (value.length > ChapterCache.MAX_CHARS / 3) {
      return;
    }
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === key) {
        this.totalChars -= this.entries[i].chars;
        this.entries.splice(i, 1);
        break;
      }
    }
    const entry = new CacheEntry();
    entry.key = key;
    entry.text = value;
    entry.chars = value.length;
    this.entries.push(entry);
    this.totalChars += entry.chars;
    this.evictIfNeeded();
  }

  private evictIfNeeded(): void {
    while (this.entries.length > ChapterCache.MAX_ENTRIES
      || (this.totalChars > ChapterCache.MAX_CHARS && this.entries.length > 1)) {
      const removed: CacheEntry | undefined = this.entries.shift();
      if (removed === undefined) {
        break;
      }
      this.totalChars -= removed.chars;
    }
  }

  clear(): void {
    this.entries = [];
    this.totalChars = 0;
  }

  size(): number {
    return this.entries.length;
  }

  /** 诊断用：当前缓存占用的字符数 */
  chars(): number {
    return this.totalChars;
  }
}
