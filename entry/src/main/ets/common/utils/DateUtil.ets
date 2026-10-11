/**
 * 日期工具。
 *
 * 统计表的 date 一律使用【本地时区】的 YYYY-MM-DD ——
 * 若用 UTC，晚上 8 点后的阅读会被算到"明天"，连续打卡天数会对不上。
 */
export class DateUtil {
  private static readonly ONE_DAY_MS: number = 24 * 60 * 60 * 1000;

  private static pad(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 时间戳 -> 本地时区 YYYY-MM-DD */
  static toDateKey(timestamp: number): string {
    const d = new Date(timestamp);
    return `${d.getFullYear()}-${DateUtil.pad(d.getMonth() + 1)}-${DateUtil.pad(d.getDate())}`;
  }

  /** 今天（本地时区） */
  static today(): string {
    return DateUtil.toDateKey(Date.now());
  }

  /** YYYY-MM-DD -> 当天 00:00:00 的时间戳（本地时区）；格式非法返回 0 */
  static fromDateKey(dateKey: string): number {
    const parts: string[] = dateKey.split('-');
    if (parts.length !== 3) {
      return 0;
    }
    const y: number = Number.parseInt(parts[0], 10);
    const m: number = Number.parseInt(parts[1], 10);
    const d: number = Number.parseInt(parts[2], 10);
    if (Number.isNaN(y) || Number.isNaN(m) || Number.isNaN(d)) {
      return 0;
    }
    return new Date(y, m - 1, d).getTime();
  }

  /** 日期前后推移若干天 */
  static shiftDateKey(dateKey: string, days: number): string {
    const base: number = DateUtil.fromDateKey(dateKey);
    if (base === 0) {
      return dateKey;
    }
    return DateUtil.toDateKey(base + days * DateUtil.ONE_DAY_MS);
  }

  /** 格式化为"刚刚 / N 分钟前 / N 小时前 / YYYY-MM-DD"，用于书架最近阅读 */
  static humanize(timestamp: number | null): string {
    if (timestamp === null || timestamp <= 0) {
      return '';
    }
    const diff: number = Date.now() - timestamp;
    if (diff < 60 * 1000) {
      return '刚刚';
    }
    if (diff < 60 * 60 * 1000) {
      return `${Math.floor(diff / (60 * 1000))} 分钟前`;
    }
    if (diff < DateUtil.ONE_DAY_MS) {
      return `${Math.floor(diff / (60 * 60 * 1000))} 小时前`;
    }
    return DateUtil.toDateKey(timestamp);
  }

  /** 秒 -> "1 小时 23 分" / "12 分钟" / "45 秒" */
  static humanizeDuration(seconds: number): string {
    if (seconds < 60) {
      return `${seconds} 秒`;
    }
    const h: number = Math.floor(seconds / 3600);
    const m: number = Math.floor((seconds % 3600) / 60);
    if (h <= 0) {
      return `${m} 分钟`;
    }
    return `${h} 小时 ${m} 分`;
  }
}
