import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AppConstants } from '../constants/AppConstants';

/**
 * 文件内容指纹（SHA-256，十六进制小写）。
 *
 * 铁律：对【原始文件字节】计算，而不是对解码后的文本计算 ——
 * 这样同一个文件无论编码被识别为 gbk 还是 utf-8，指纹都一致，去重才可靠。
 *
 * 流式读取，禁止一次性读入内存。
 */
export class HashUtil {
  static async fileSha256(absolutePath: string): Promise<string> {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const file = fs.openSync(absolutePath, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(AppConstants.HASH_CHUNK_BYTES);
      let offset: number = 0;
      while (true) {
        const readLen: number = fs.readSync(file.fd, buffer, { offset: offset });
        if (readLen <= 0) {
          break;
        }
        const chunk = new Uint8Array(buffer, 0, readLen);
        const blob: cryptoFramework.DataBlob = { data: chunk };
        await md.update(blob);
        offset += readLen;
      }
    } finally {
      fs.closeSync(file);
    }
    const digest: cryptoFramework.DataBlob = await md.digest();
    return HashUtil.toHex(digest.data);
  }

  private static toHex(bytes: Uint8Array): string {
    let out: string = '';
    for (let i = 0; i < bytes.length; i++) {
      const b: number = bytes[i];
      out += b < 16 ? `0${b.toString(16)}` : b.toString(16);
    }
    return out;
  }
}
