import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Book } from '../../model/Book';
import { Annotation } from '../../model/Annotation';
import { BookRepository, BookSort } from '../repository/BookRepository';
import { AnnotationRepository } from '../repository/AnnotationRepository';
import { AppConstants } from '../../common/constants/AppConstants';
import { PathUtil } from '../../common/utils/PathUtil';
import { LogTag } from '../../common/constants/AppConstants';
import { Logger } from '../../common/utils/Logger';

/** 备份文件里的一本书（uuid 是跨设备/跨库的唯一锚点） */
interface BackupBook {
  uuid: string;
  title: string;
  author: string;
  /** 阅读进度：章内 0-based + 章内 UTF-16 偏移 */
  lastChapterIndex: number;
  lastOffset: number;
  /** 这本书的全部标注（含 deleted=0 的有效标注） */
  annotations: BackupAnnotation[];
}

/** 备份文件里的一条标注（去掉 id/chapterId 等库内字段 —— 它们在恢复时重建） */
interface BackupAnnotation {
  chapterIndex: number;
  type: number;
  startOffset: number | null;
  endOffset: number | null;
  selectedText: string;
  noteContent: string;
  color: string;
  createdAt: number;
}

/** 备份文件顶层结构（版本号先行，将来字段变更可迁移） */
interface BackupFile {
  version: number;
  /** 导出时间戳（ms） */
  exportedAt: number;
  books: BackupBook[];
}

/**
 * 数据备份/恢复服务 —— 「我的」页「数据管理」的后端。
 *
 * ## 范围（刻意收窄）
 * 只备份**用户亲手创造的数据**：书签、划线、笔记、阅读进度。
 * 不备份书源 TXT 本身（几十 MB 且要用户在文件管理器里自己管）、
 * 不备份分页缓存（可重建）、不备份统计（丢了好过丢标注）。
 *
 * ## 流程
 *  - 导出：读库 → 组 JSON → 写沙箱临时文件 → `DocumentViewPicker` 让用户选保存位置
 *    （picker 拿到的 URI 才能写到用户目录，直接写沙箱外路径会被权限拦）
 *  - 导入：`DocumentSelectOptions` 让用户挑文件 → 读回 JSON → **按书 uuid 匹配**：
 *      · 书在库 → 标注按"内容+章节+偏移"去重后插入，进度取"更靠后的那个"
 *      · 书不在库 → 该书条目跳过（书源 TXT 都不在了，恢复标注没有锚点）
 *
 * ⚠️ 恢复**不是**整库替换：合并式（去重）让"导出 → 又读了一会儿 → 导入"
 * 不丢任何一边的数据。
 */
export class BackupService {
  private static readonly BACKUP_VERSION: number = 1;
  /** 导入时把用户文件拷进沙箱的副本名（读完即删） */
  private static readonly IMPORT_TEMP_NAME: string = 'jingdu-import.json';

  // ------------------------------------------------------------ 导出

  /**
   * 生成备份 JSON 文本（导出与"复制到剪贴板"共用）。
   * @returns JSON 字符串；书架为空时返回空串（调用方提示"没有可备份的数据"）
   */
  static async buildBackupJson(): Promise<string> {
    const books: Book[] = await BookRepository.listShelf(BookSort.LAST_READ, null);
    if (books.length === 0) {
      return '';
    }
    const file: BackupFile = {
      version: BackupService.BACKUP_VERSION,
      exportedAt: Date.now(),
      books: []
    };
    for (const b of books) {
      const annotations: Annotation[] =
        await AnnotationRepository.listAllForExport(b.id);
      const item: BackupBook = {
        uuid: b.uuid,
        title: b.title,
        author: b.author,
        lastChapterIndex: b.lastChapterIndex,
        lastOffset: b.lastOffset,
        annotations: annotations.map((a: Annotation): BackupAnnotation => {
          return {
            chapterIndex: a.chapterIndex,
            type: a.type,
            startOffset: a.startOffset,
            endOffset: a.endOffset,
            selectedText: a.selectedText,
            noteContent: a.noteContent,
            color: a.color,
            createdAt: a.createdAt
          };
        })
      };
      file.books.push(item);
    }
    return JSON.stringify(file);
  }

  /**
   * 导出：生成 JSON → 弹保存面板 → **直接写入用户选的位置**。
   *
   * ## 为什么不再走"沙箱中转 + 拷贝"
   *
   * 早先的实现是：写沙箱临时文件 → 弹面板 → `copyFile` 到 picker URI →
   * 删临时文件。真机上这条路走不通，两个坑都在 picker 的 URI 上：
   *  - `fs.copyFile(fd, uri)` 报 "No such file or directory"（URI 不能当路径解析）；
   *  - 改成 `openSync(uri, CREATE)` + fd 拷贝后，`statSync(uri)` 又不可用
   *    （picker URI 不是可 stat 的路径），整个流程抛在英文异常上，
   *    用户只看到兜底的"导出失败"。
   *
   * 现在只做**一次写入**：save 面板返回的 URI 自带写授权，
   * 直接 `openSync(uri, CREATE|TRUNC)` 拿到 fd 写字节，写完关掉就结束 ——
   * 没有中转文件、没有拷贝、没有对 URI 的 stat，链路短到没有出错空间。
   *
   * ⚠️ 每一步的失败都换成**各自的中文文案**：底层异常（fs/picker）的
   * message 是英文，不能让它漏进 toast，也不能都退化成同一句"导出失败"
   * ——那样用户和我们都不知道卡在哪一步。
   *
   * @returns 用户是否完成了保存（取消 = false）
   */
  static async exportToUser(): Promise<boolean> {
    const json: string = await BackupService.buildBackupJson();
    if (json.length === 0) {
      throw new Error('书架为空，没有可备份的数据');
    }

    // 先编码成字节：`writeSync(fd, string)` 在部分版本上会静默丢内容
    // （文件建出来是 0 KB），必须走 Uint8Array（SelfCheckPage 的成熟写法）。
    const encoder: util.TextEncoder = new util.TextEncoder();
    const bytes: Uint8Array = encoder.encodeInto(json);

    // 1) 弹保存面板
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [`jingdu-backup-${BackupService.dateStamp()}.json`];
    let uris: Array<string> = [];
    try {
      uris = await new picker.DocumentViewPicker().save(options);
    } catch (e) {
      Logger.error(LogTag.BACKUP, `保存面板打开失败: ${Logger.errText(e as Object)}`);
      throw new Error('无法打开保存面板，请重试或检查文件管理权限');
    }
    if (uris === undefined || uris.length === 0) {
      return false; // 用户取消：不提示（自己点的取消，弹提示是打扰）
    }

    // 2) 直接写入用户选定的位置
    let file: fs.File | null = null;
    let written: number = 0;
    try {
      file = fs.openSync(uris[0],
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      written = fs.writeSync(file.fd, bytes.buffer.slice(0, bytes.length));
    } catch (e) {
      Logger.error(LogTag.BACKUP, `备份写入失败: ${Logger.errText(e as Object)}`);
      throw new Error('无法写入所选位置，请换一个文件夹再试');
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }

    // 3) 校验写入长度：短写说明没落全，当场报错而不是留个残文件
    if (written !== bytes.length) {
      throw new Error(`备份写入不完整（${written}/${bytes.length} 字节），请重试`);
    }
    return true;
  }

  // ------------------------------------------------------------ 导入

  /**
   * 导入：弹"选择文件"面板 → 拷进沙箱 → 读 JSON → 按 uuid 合并。
   * @returns 恢复的标注条数与更新的书数（用于结果提示）
   */
  static async importFromUser(): Promise<ImportResult> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.json', 'application/json'];
    const loader = new picker.DocumentViewPicker();
    const uris: Array<string> = await loader.select(options);
    if (uris === undefined || uris.length === 0) {
      const cancelled = new ImportResult();
      cancelled.cancelled = true;
      return cancelled;
    }

    /**
     * ⚠️ 先拷进沙箱再读 —— 与 FilePickerSource.copyToSandbox 同一做法。
     *
     * 直接 `fs.openSync(uri)` + `fs.readSync(fd)` 在部分版本上对
     * media/docs URI 会报 "No such file or directory"（URI 的读授权
     * 覆盖 stat/copy 但 open 行为随实现浮动）；copy 到沙箱路径后
     * 就是在读一个普通本地文件，零歧义。
     */
    const sandboxPath: string = `${PathUtil.backupDir()}/${BackupService.IMPORT_TEMP_NAME}`;
    PathUtil.ensureDir(PathUtil.backupDir());
    const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
    try {
      await fs.copyFile(src.fd, sandboxPath);
    } finally {
      fs.closeSync(src);
    }

    // 从沙箱副本读取 JSON。
    //
    // ⚠️ `readSync(fd, buf)` 不带 options 时**不保证读满**，而且这里
    // 必须显式传 `offset: 0, length: stat.size` —— 空读正是
    // "Unexpected Text in JSON: Empty Text"（JSON.parse 拿到空串）的原因。
    // 零字节文件在这里直接判错（中文文案），不让英文异常漏到 toast。
    let raw: string = '';
    const file = fs.openSync(sandboxPath, fs.OpenMode.READ_ONLY);
    try {
      const stat: fs.Stat = fs.statSync(sandboxPath);
      if (stat.size <= 0) {
        throw new Error('备份文件是空的，请重新导出一次');
      }
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      const readLen: number = fs.readSync(file.fd, buf, { offset: 0, length: stat.size });
      if (readLen <= 0) {
        throw new Error('备份文件读不出内容，请重新导出一次');
      }
      raw = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf.slice(0, readLen)));
    } finally {
      fs.closeSync(file);
      try {
        if (fs.accessSync(sandboxPath)) {
          fs.unlinkSync(sandboxPath);
        }
      } catch (e) {
        // 沙箱副本删不掉不影响导入结果
      }
    }

    let parsed: BackupFile;
    try {
      parsed = JSON.parse(raw) as BackupFile;
    } catch (e) {
      // ⚠️ JSON.parse 的异常是英文（"Unexpected Text in JSON"），
      // 必须在这里拦下换成中文，否则会原样漏进 toast。
      throw new Error('备份文件内容不是有效的 JSON，可能已损坏');
    }
    if (parsed === null || parsed.books === undefined || parsed.books === null) {
      throw new Error('文件格式不对，不是静读的备份文件');
    }

    const result = new ImportResult();
    for (const item of parsed.books) {
      // 按 uuid 找库里的书（uuid 是导入文件时生成的稳定标识）
      const found = await BookRepository.getByUuid(item.uuid);
      if (found === null) {
        result.skippedBooks += 1;
        continue;
      }
      result.restoredBooks += 1;

      // 进度：取"更靠后的"（本地可能比备份新，也可能旧）
      if (item.lastChapterIndex > found.lastChapterIndex
        || (item.lastChapterIndex === found.lastChapterIndex
          && item.lastOffset > found.lastOffset)) {
        /**
         * ⚠️ percent 与 location 需要与章节/偏移自洽：
         * percent 这里按"章进度"粗算（章号/总章数），精确百分比要分页数据，
         * 恢复场景下粗算可接受 —— 用户读几页后 ProgressService 会立刻覆盖为真值。
         * location 用 buildLocation 组标准格式，阅读页打开时直接可解析。
         */
        const total: number = found.totalChapters > 0 ? found.totalChapters : 1;
        const percent: number = Math.min(1, item.lastChapterIndex / total);
        await BookRepository.updateProgress(
          found.id, item.lastChapterIndex, item.lastOffset, percent,
          BookRepository.buildLocation(item.lastChapterIndex, item.lastOffset, percent),
          AppConstants.READ_STATUS_READING);
        result.updatedProgress += 1;
      }

      // 标注：逐条去重后插入（同书同章同偏移同内容 = 已存在）
      for (const a of item.annotations) {
        const exists: boolean = await BackupService.annotationExists(found.id, a);
        if (exists) {
          result.duplicates += 1;
          continue;
        }
        await AnnotationRepository.add(
          found.id, a.chapterIndex, a.type,
          a.startOffset, a.endOffset,
          a.selectedText, a.noteContent, a.color);
        result.restoredAnnotations += 1;
      }
    }
    return result;
  }

  /** 判断一条备份标注是否已在库里（同章 + 同类型 + 同起始偏移 + 同内容） */
  private static async annotationExists(bookId: number, a: BackupAnnotation): Promise<boolean> {
    const list: Annotation[] =
      await AnnotationRepository.listByBook(bookId, AppConstants.ANNOTATION_ALL);
    for (const existing of list) {
      if (existing.chapterIndex === a.chapterIndex
        && existing.type === a.type
        && existing.startOffset === a.startOffset
        && existing.selectedText === a.selectedText) {
        return true;
      }
    }
    return false;
  }

  /** 文件名日期戳：20260115 */
  private static dateStamp(): string {
    const d: Date = new Date();
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
  }
}

/** 导入结果（供页面组织提示文案） */
export class ImportResult {
  /** 用户在 picker 取消 */
  cancelled: boolean = false;
  /** 匹配到库内书并处理了标注/进度的书数 */
  restoredBooks: number = 0;
  /** 备份里有、但书架没有的书数（跳过） */
  skippedBooks: number = 0;
  /** 恢复的标注条数 */
  restoredAnnotations: number = 0;
  /** 判定为重复而跳过的标注条数 */
  duplicates: number = 0;
  /** 更新了进度的书数 */
  updatedProgress: number = 0;

  /** 一句话结果文案 */
  summary(): string {
    if (this.skippedBooks > 0) {
      return `恢复 ${this.restoredBooks} 本 / ${this.restoredAnnotations} 条标注，${this.skippedBooks} 本书不在书架已跳过`;
    }
    return `恢复 ${this.restoredBooks} 本 / ${this.restoredAnnotations} 条标注`;
  }
}
