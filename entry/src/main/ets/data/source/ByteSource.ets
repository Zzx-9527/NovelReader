/**
 * 字节读取接口。
 *
 * ChapterParser（分章）与 ChapterReadService（读章）都只依赖这个接口，
 * 不直接依赖 @ohos.file.fs —— 这样解析逻辑可以脱离设备单测，
 * 也便于将来换成别的数据源（如解压后的内存数据）而无需改动消费方。
 */
export interface ByteSource {
  /** 源的总字节数 */
  size(): number;

  /**
   * 顺序读取：从 offset 处最多读 length 字节。
   * 返回实际读到的字节；读到末尾返回长度为 0 的数组。
   */
  readChunk(offset: number, length: number): Uint8Array;

  /**
   * 随机读取整段区间 [start, end)。
   * end 为 null 表示读到文件末尾（调用方应自行设置上限，避免大文件 OOM）。
   */
  readRange(start: number, end: number | null): Uint8Array;

  /** 关闭底层资源 */
  close(): void;
}
