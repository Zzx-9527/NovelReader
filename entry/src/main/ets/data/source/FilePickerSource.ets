import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../common/utils/Logger';
import { LogTag } from '../../common/constants/AppConstants';

/**
 * 系统文件选择器封装。
 *
 * 单独抽一层的原因：picker 会弹出系统 UI、依赖 Context，
 * 把它隔离在这里，ImportService 就只依赖"给我一个 URI"这个契约，
 * 便于测试与将来替换（例如从分享意图拿到 URI）。
 */
export class FilePickerSource {
  /**
   * 弹出文件选择器，最多选 1 个 .txt 文件。
   * @returns 选中的 URI；用户取消返回空串
   */
  static async pickTextFile(): Promise<string> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.txt', 'text/plain'];
    const viewPicker = new picker.DocumentViewPicker();
    try {
      const uris: Array<string> = await viewPicker.select(options);
      if (uris === undefined || uris === null || uris.length === 0) {
        return '';
      }
      return uris[0];
    } catch (e) {
      // 用户取消通常也走异常分支，这里按取消处理，只记日志
      Logger.info(LogTag.IMPORT, `文件选择未完成: ${Logger.errText(e as BusinessError)}`);
      return '';
    }
  }

  /** 文件大小（字节）；失败返回 0 */
  static fileSize(uri: string): number {
    try {
      return fs.statSync(uri).size;
    } catch (e) {
      return 0;
    }
  }

  /**
   * 把 picker 返回的 URI 复制进沙箱。
   *
   * picker 给的授权是临时的，必须复制后文件才能长期使用。
   * 一律通过 fd 复制，避免依赖 URI 与路径之间的转换细节。
   */
  static async copyToSandbox(uri: string, destAbsolutePath: string): Promise<void> {
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      await fs.copyFile(src.fd, destAbsolutePath);
    } finally {
      fs.closeSync(src);
    }
  }
}
