import { AppConstants } from '../../common/constants/AppConstants';

/**
 * 章节正文 LRU 缓存。
 *
 * 为什么不用 Map：ArkTS 对跨模块集合类型的支持有不确定性，
 * 缓存容量只有几章，用两个平行数组最简单可靠。
 */
export class ChapterCache {
  private keys: string[] = [];
  private values: string[] = [];

  get(key: string): string | null {
    for (let i = 0; i < this.keys.length; i++) {
      if (this.keys[i] === key) {
        const value: string = this.values[i];
        // 命中后移到末尾（最近使用）
        this.keys.splice(i, 1);
        this.values.splice(i, 1);
        this.keys.push(key);
        this.values.push(value);
        return value;
      }
    }
    return null;
  }

  put(key: string, value: string): void {
    for (let i = 0; i < this.keys.length; i++) {
      if (this.keys[i] === key) {
        this.keys.splice(i, 1);
        this.values.splice(i, 1);
        break;
      }
    }
    this.keys.push(key);
    this.values.push(value);
    while (this.keys.length > AppConstants.CHAPTER_CACHE_SIZE) {
      this.keys.shift();
      this.values.shift();
    }
  }

  clear(): void {
    this.keys = [];
    this.values = [];
  }

  size(): number {
    return this.keys.length;
  }
}
