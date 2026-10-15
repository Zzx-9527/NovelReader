import { fileIo as fs } from '@kit.CoreFileKit';
import { ByteSource } from './ByteSource';
import { AppConstants, LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';

/**
 * 沙箱文件的 ByteSource 实现。
 *
 * 关键点：一律使用 fs.read(fd, buffer, { offset, length }) 做**按字节随机读**，
 * 绝不 fs.readText 整读 —— 大文件必然 OOM。
 */
export class RawFileSource implements ByteSource {
  private fd: number = -1;
  private fileSize: number = 0;
  private filePath: string = '';
  /**
   * 是否已释放。
   *
   * ⚠️ 光靠 `fd < 0` 判断是不够的：`close()` 之后 fd 被置 -1，
   * 但**文件描述符会被系统复用**给下一个打开的文件 —— 此时若还有人
   * 拿着这个已废弃的 source 去读，`fd` 若被误设成新值就会读到**别人的数据**。
   * 所以用一个独立的布尔位标记释放状态，读操作一律先看它。
   *
   * 这正是"重复打开阅读页导致 fd 泄漏 → 白屏"那条链路的配套防护：
   * 泄漏由调用方修（见 `ReaderViewModel.open`），这里保证
   * "释放过就一定不会再被使用"。
   */
  private disposed: boolean = false;

  private constructor(path: string, fd: number, size: number) {
    this.filePath = path;
    this.fd = fd;
    this.fileSize = size;
  }

  /**
   * 打开文件。失败抛异常，由调用方决定如何呈现。
   * 用完必须 close()。
   */
  static open(absolutePath: string): RawFileSource {
    const file = fs.openSync(absolutePath, fs.OpenMode.READ_ONLY);
    let size: number = 0;
    try {
      size = fs.statSync(absolutePath).size;
    } catch (e) {
      fs.closeSync(file);
      throw e as Error;
    }
    return new RawFileSource(absolutePath, file.fd, size);
  }

  /** 安全打开：失败返回 null，不抛异常 */
  static tryOpen(absolutePath: string): RawFileSource | null {
    try {
      return RawFileSource.open(absolutePath);
    } catch (e) {
      Logger.warn(LogTag.READ, `打开文件失败: ${absolutePath} - ${Logger.errText(e as Object)}`);
      return null;
    }
  }

  /** 是否已释放（诊断用） */
  isDisposed(): boolean {
    return this.disposed;
  }

  size(): number {
    return this.fileSize;
  }

  path(): string {
    return this.filePath;
  }

  readChunk(offset: number, length: number): Uint8Array {
    if (this.disposed || this.fd < 0 || offset >= this.fileSize || length <= 0) {
      return new Uint8Array(0);
    }
    const want: number = Math.min(length, this.fileSize - offset);
    if (want <= 0) {
      return new Uint8Array(0);
    }
    const buffer = new ArrayBuffer(want);
    try {
      const got: number = fs.readSync(this.fd, buffer, { offset: offset, length: want });
      if (got <= 0) {
        return new Uint8Array(0);
      }
      return new Uint8Array(buffer, 0, got);
    } catch (e) {
      Logger.error(LogTag.READ, `读取失败 offset=${offset}: ${Logger.errText(e as Object)}`);
      return new Uint8Array(0);
    }
  }

  readRange(start: number, end: number | null): Uint8Array {
    if (this.disposed || start < 0 || start >= this.fileSize) {
      return new Uint8Array(0);
    }
    let stop: number = end === null ? this.fileSize : Math.min(end, this.fileSize);
    if (stop <= start) {
      return new Uint8Array(0);
    }
    const total: number = stop - start;
    const out = new Uint8Array(total);
    const buffer = new ArrayBuffer(Math.min(total, AppConstants.READ_CHUNK_BYTES));
    let written: number = 0;
    while (written < total) {
      const want: number = Math.min(buffer.byteLength, total - written);
      let got: number = 0;
      try {
        got = fs.readSync(this.fd, buffer, { offset: start + written, length: want });
      } catch (e) {
        Logger.error(LogTag.READ, `区间读取失败: ${Logger.errText(e as Object)}`);
        break;
      }
      if (got <= 0) {
        break;
      }
      out.set(new Uint8Array(buffer, 0, got), written);
      written += got;
    }
    return written === total ? out : out.subarray(0, written);
  }

  /**
   * 释放文件描述符。**幂等**：重复调用是安全的。
   *
   * ⚠️ 幂等不能省：调用方（`ChapterReadService.dispose` → `RawFileSource.close`）
   * 可能被多路径触发，而重复 `closeSync` 同一个 fd 会关掉**别的**文件
   * （fd 已被系统复用给新打开的文件），是极难排查的数据损坏。
   */
  close(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    if (this.fd >= 0) {
      try {
        fs.closeSync(this.fd);
      } catch (e) {
        // 关闭失败无需上抛
      }
      this.fd = -1;
    }
  }
}
