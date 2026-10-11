/** 文件大小格式化：用于书籍详情与导入确认页 */
export class FileUtil {
  /** 字节 -> "1.2 MB" / "356 KB" / "892 B" */
  static humanSize(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    const kb: number = bytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb: number = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(2)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  /** 字数格式化：超过一万显示"1.2 万字" */
  static humanCount(count: number): string {
    if (count <= 0) {
      return '0';
    }
    if (count < 10000) {
      return `${count} 字`;
    }
    return `${(count / 10000).toFixed(1)} 万字`;
  }

  /** 0~1 -> "23.5%" */
  static humanPercent(percent: number): string {
    const clamped: number = percent < 0 ? 0 : (percent > 1 ? 1 : percent);
    return `${(clamped * 100).toFixed(1)}%`;
  }
}
