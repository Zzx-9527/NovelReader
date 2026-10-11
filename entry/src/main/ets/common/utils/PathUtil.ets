import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { AppConstants } from '../constants/AppConstants';

/**
 * 沙箱路径工具。
 *
 * 铁律：数据库里只存【相对路径】，绝对路径由这里在运行时拼接 ——
 * 应用升级/迁移后 filesDir 会变，存绝对路径必然失效。
 */
export class PathUtil {
  private static filesDir: string = '';

  static init(context: common.Context): void {
    PathUtil.filesDir = context.filesDir;
    PathUtil.ensureDir(PathUtil.filesDir);
  }

  static isReady(): boolean {
    return PathUtil.filesDir.length > 0;
  }

  static getFilesDir(): string {
    return PathUtil.filesDir;
  }

  /** 相对路径 -> 绝对路径（已是绝对路径则原样返回） */
  static toAbsolute(relativePath: string): string {
    if (relativePath.startsWith('/')) {
      return relativePath;
    }
    return `${PathUtil.filesDir}/${relativePath}`;
  }

  static booksDir(): string {
    return `${PathUtil.filesDir}/${AppConstants.DIR_BOOKS}`;
  }

  static coversDir(): string {
    return `${PathUtil.filesDir}/${AppConstants.DIR_COVERS}`;
  }

  static backupDir(): string {
    return `${PathUtil.filesDir}/${AppConstants.DIR_BACKUP}`;
  }

  /** 某本书的沙箱相对路径 */
  static bookRelativePath(uuid: string): string {
    return `${AppConstants.DIR_BOOKS}/${uuid}${AppConstants.EXT_TXT}`;
  }

  /** 某本书封面的沙箱相对路径 */
  static coverRelativePath(uuid: string): string {
    return `${AppConstants.DIR_COVERS}/${uuid}${AppConstants.EXT_JPG}`;
  }

  /** 建目录（递归），已存在则跳过 */
  static ensureDir(path: string): void {
    if (path.length === 0) {
      return;
    }
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
  }

  /** 文件是否存在（传相对或绝对都可以） */
  static exists(relativeOrAbsolute: string): boolean {
    if (relativeOrAbsolute.length === 0 || !PathUtil.isReady()) {
      return false;
    }
    try {
      return fs.accessSync(PathUtil.toAbsolute(relativeOrAbsolute));
    } catch (e) {
      return false;
    }
  }

  /** 文件大小；不存在返回 0 */
  static fileSize(relativeOrAbsolute: string): number {
    if (relativeOrAbsolute.length === 0 || !PathUtil.isReady()) {
      return 0;
    }
    try {
      return fs.statSync(PathUtil.toAbsolute(relativeOrAbsolute)).size;
    } catch (e) {
      return 0;
    }
  }

  /** 从 URI 或路径中提取不含扩展名的文件名，用作书名兜底 */
  static fileNameWithoutExt(uriOrPath: string): string {
    let name: string = uriOrPath;
    const slash: number = name.lastIndexOf('/');
    if (slash >= 0) {
      name = name.substring(slash + 1);
    }
    try {
      name = decodeURIComponent(name);
    } catch (e) {
      // URI 解码失败就用原样，不影响导入
    }
    const dot: number = name.lastIndexOf('.');
    if (dot > 0) {
      name = name.substring(0, dot);
    }
    return name.length > 0 ? name : '未命名';
  }
}
