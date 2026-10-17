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

  /**
   * 递归统计一个目录的总大小（字节）。
   *
   * ⚠️ 全部用**同步** API（`listFile`/`statSync`）：调用点在「我的」页
   * 打开时算一次，书籍文件通常几十 MB 量级、文件数几十个，同步遍历
   * 几毫秒完成，不值得为它引入异步聚合的复杂度。
   *
   * ⚠️ 任何一项读取失败（权限/文件恰好被删）都**按 0 计**并继续：
   * 统计是展示性信息，一项失败不应该让整行显示不出来。
   *
   * @param absoluteDir 目录绝对路径；不存在返回 0
   */
  static dirSize(absoluteDir: string): number {
    if (absoluteDir.length === 0 || !PathUtil.isReady()) {
      return 0;
    }
    let total: number = 0;
    try {
      if (!fs.accessSync(absoluteDir)) {
        return 0;
      }
      const names: string[] = fs.listFileSync(absoluteDir);
      for (const name of names) {
        const child: string = `${absoluteDir}/${name}`;
        try {
          const stat = fs.statSync(child);
          if (stat.isDirectory()) {
            total += PathUtil.dirSize(child);
          } else {
            total += stat.size;
          }
        } catch (e) {
          // 单个条目失败按 0 计，继续统计其余
        }
      }
    } catch (e) {
      // 目录不可读：返回已累计的部分
    }
    return total;
  }

  /**
   * 沙箱**数据目录**的总占用（书籍文件 + 封面 + 备份 + 数据库等）。
   *
   * ⚠️ 统计的是 `filesDir` 整棵树 —— 它就是"这个应用存的书与数据"的全部：
   *  - `books/`：导入的 TXT 原文件（占大头）；
   *  - `covers/`：封面图（当前 TXT 导入不产封面文件，此目录通常为空）；
   *  - `backup/`：本地备份残留；
   *  - 数据库与 Preferences 在 `filesDir` 之外的 `database`/`preferences`
   *    目录，**不在**这棵树里 —— 本方法特意不去够那些（跨目录统计要
   *    再注入一个 context 路径，而它们通常只占几百 KB），
   *    行文案上写清"书籍文件"即可对齐口径。
   */
  static sandboxUsage(): number {
    return PathUtil.dirSize(PathUtil.getFilesDir());
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
