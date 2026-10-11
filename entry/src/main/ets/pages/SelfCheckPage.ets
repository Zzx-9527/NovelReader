import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { relationalStore } from '@kit.ArkData';

import { RdbHelper } from '../data/database/RdbHelper';
import { SettingsService } from '../data/service/SettingsService';
import { ChapterReadService } from '../data/service/ChapterReadService';
import { ImportService, ImportPreparation, ImportResult, ImportOutcome } from '../data/service/ImportService';
import { ProgressService, RestoredPosition } from '../data/service/ProgressService';
import { StatsService } from '../data/service/StatsService';
import { PaginationService } from '../data/service/PaginationService';
import { BookRepository, BookSort, HashLookup } from '../data/repository/BookRepository';
import { ChapterRepository } from '../data/repository/ChapterRepository';
import { AnnotationRepository } from '../data/repository/AnnotationRepository';
import { PageCacheRepository } from '../data/repository/PageCacheRepository';
import { RawFileSource } from '../data/source/RawFileSource';
import { Book } from '../model/Book';
import { Chapter } from '../model/Chapter';
import { PathUtil } from '../common/utils/PathUtil';
import { EncodingDetector, DetectionResult, Encodings } from '../common/utils/EncodingDetector';
import { ChapterParser, ParseResult, ParsedChapter } from '../common/utils/ChapterParser';
import { ByteLength } from '../common/utils/ByteLength';
import { Logger } from '../common/utils/Logger';
import { StorageBootstrap } from '../common/StorageBootstrap';
import { AppTheme } from '../common/theme/AppTheme';
import { DbConstants } from '../common/constants/DbConstants';
import { SettingsKeys } from '../common/constants/SettingsKeys';
import { AppConstants } from '../common/constants/AppConstants';

/** 自检项 */
interface CheckItem {
  name: string;
  ok: boolean;
  detail: string;
}

/**
 * 用于文件 I/O 验证的 UTF-8 测试文本。
 * 前言段刻意小于 AppConstants.PREFACE_MIN_BYTES(200)，因此不会生成"前言"章节。
 */
const SAMPLE_TEXT: string =
  '作品：测试小说\n\n前言部分的内容，用来验证首章之前的文本。\n\n' +
  '第一章 初入江湖\n这是第一章的正文。\n第二行。\n\n' +
  '第二章 风起云涌\n这是第二章的正文。\n\n' +
  '第三章 尘埃落定\n这是第三章的正文，也是最后一章。\n';

/** 各章正文的预期内容（与 SAMPLE_TEXT 严格对应） */
const EXPECTED_CHAPTERS: string[] = [
  '这是第一章的正文。\n第二行。\n\n',
  '这是第二章的正文。\n\n',
  '这是第三章的正文，也是最后一章。\n'
];

/** 内存字节校验样本：同一文本的 UTF-8(61B) 与 GB18030(28B) 编码 */
const PROBE_TEXT: string = '第一章 风起\n这是正文。行二。';

const PROBE_UTF8: number[] = [
  0xE7, 0xAC, 0xAC, 0xE4, 0xB8, 0x80, 0xE7, 0xAB, 0xA0, 0x20,
  0xE9, 0xA3, 0x8E, 0xE8, 0xB5, 0xB7, 0x0A,
  0xE8, 0xBF, 0x99, 0xE6, 0x98, 0xAF, 0xE6, 0xAD, 0xA3, 0xE6, 0x96, 0x87,
  0xE3, 0x80, 0x82,
  0xE8, 0xA1, 0x8C, 0xE4, 0xBA, 0x8C,
  0xE3, 0x80, 0x82
];

const PROBE_GBK: number[] = [
  0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x20,
  0xB7, 0xE7, 0xC6, 0xF0, 0x0A,
  0xD5, 0xE2, 0xCA, 0xC7, 0xD5, 0xFD, 0xCE, 0xC4, 0xA1, 0xA3,
  0xD0, 0xD0, 0xB6, 0xFE, 0xA1, 0xA3
];

/** 期望存在的核心索引（缺失会影响正确性） */
const EXPECTED_CORE_INDEXES: string[] = [
  'uq_book_uuid', 'uq_book_hash', 'idx_book_shelf', 'idx_book_group',
  'idx_chapter_title', 'idx_annotation_book', 'uq_group_name', 'uq_page_cache'
];

/** 辅助索引（缺失只影响性能） */
const EXPECTED_AUX_INDEXES: string[] = [
  'idx_book_status', 'idx_annotation_chapter', 'idx_annotation_type',
  'idx_group_sort', 'uq_stats_book_date', 'idx_stats_date', 'idx_page_cache_book'
];

/** 单调递增序号，保证探测用的 uuid 唯一（不用 Math.random） */
let probeSeq: number = 0;

function nextUuid(prefix: string): string {
  probeSeq++;
  return `${prefix}-${Date.now()}-${probeSeq}`;
}

/**
 * 底座自检页（开发用）。
 *
 * 保留它的价值：这 10 项曾经抓出过 6 个真实 bug（事务内回查、旧库结构过期、
 * 标题混进正文、TimeEncoder 算错字节、GBK 误判 UTF-16、外键未生效）。
 * 入口：我的 → 自检页。正式发布前可移除。
 */
@Entry
@Component
struct SelfCheckPage {
  @State checks: CheckItem[] = [];
  @State running: boolean = false;
  @State summary: string = '正在自检…';

  aboutToAppear(): void {
    this.runAll();
  }

  build() {
    Column({ space: AppTheme.GAP_M }) {
      Column({ space: 4 }) {
        Text('阅读器 · 底座自检')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .width('100%')
        Text(this.summary)
          .fontSize(13)
          .fontColor('#666666')
          .width('100%')
      }
      .width('100%')

      List({ space: 8 }) {
        ForEach(this.checks, (item: CheckItem) => {
          ListItem() {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Text(item.ok ? '✓' : '✗')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(item.ok ? '#1B9C4B' : '#D33A2C')
                Text(item.name)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .layoutWeight(1)
              }
              .width('100%')

              Text(item.detail)
                .fontSize(12)
                .fontColor('#888888')
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(10)
            .backgroundColor('#F5F5F5')
            .borderRadius(8)
          }
        }, (item: CheckItem) => item.name)
      }
      .layoutWeight(1)
      .width('100%')

      Button(this.running ? '自检中…' : '重新自检')
        .enabled(!this.running)
        .width('100%')
        .onClick(() => {
          this.runAll();
        })
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }

  private addCheck(name: string, ok: boolean, detail: string): void {
    const item: CheckItem = { name: name, ok: ok, detail: detail };
    this.checks.push(item);
  }

  private static containsName(names: string[], target: string): boolean {
    for (const name of names) {
      if (name === target) {
        return true;
      }
    }
    return false;
  }

  private async runAll(): Promise<void> {
    this.running = true;
    this.checks = [];
    this.summary = '正在自检…';

    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      StorageBootstrap.bootstrap(context);
      await StorageBootstrap.ensureReady();

      this.checkPath();
      await this.checkDatabase();
      await this.checkSettings();
      this.checkByteLengthAndDecoder();
      await this.checkEncodingAndParser(Encodings.UTF8, 'probe-utf8.txt');
      await this.checkDataPipeline();
      await this.probeTransactionInsert();
    } catch (e) {
      this.addCheck('自检初始化', false, Logger.errText(e as Object));
    }

    this.running = false;
    let failed: number = 0;
    for (const c of this.checks) {
      if (!c.ok) {
        failed++;
      }
    }
    this.summary = failed === 0
      ? `全部 ${this.checks.length} 项通过`
      : `${this.checks.length} 项中 ${failed} 项未通过`;
  }

  /** 1) 沙箱路径 */
  private checkPath(): void {
    try {
      this.addCheck('沙箱路径', PathUtil.isReady(), `filesDir = ${PathUtil.getFilesDir()}`);
    } catch (e) {
      this.addCheck('沙箱路径', false, Logger.errText(e as Object));
    }
  }

  /** 2) 建表 + 索引 + 外键级联 */
  private async checkDatabase(): Promise<void> {
    try {
      const db = RdbHelper.getInstance();
      const tables: string[] = [
        DbConstants.TABLE_BOOK, DbConstants.TABLE_CHAPTER, DbConstants.TABLE_ANNOTATION,
        DbConstants.TABLE_BOOK_GROUP, DbConstants.TABLE_DAILY_STATS, DbConstants.TABLE_PAGE_CACHE
      ];
      const missingTables: string[] = [];
      for (const t of tables) {
        if (!await db.hasTable(t)) {
          missingTables.push(t);
        }
      }
      if (missingTables.length > 0) {
        this.addCheck('数据库建表', false, `缺少表：${missingTables.join(', ')}`);
        return;
      }

      const actual: string[] = await db.listIndexNames();
      const missingCore: string[] = [];
      for (const expected of EXPECTED_CORE_INDEXES) {
        if (!SelfCheckPage.containsName(actual, expected)) {
          missingCore.push(expected);
        }
      }
      const missingAux: string[] = [];
      for (const expected of EXPECTED_AUX_INDEXES) {
        if (!SelfCheckPage.containsName(actual, expected)) {
          missingAux.push(expected);
        }
      }
      const fkEnforced: boolean = await db.verifyForeignKeyEnforced();

      this.addCheck('数据库建表', missingCore.length === 0 && fkEnforced,
        `${DbConstants.DB_NAME} · 6 张表 · 索引 ${actual.length} 条` +
        (missingCore.length > 0 ? ` · 缺核心:${missingCore.join(',')}` : '') +
        (missingAux.length > 0 ? ` · 缺辅助:${missingAux.join(',')}` : '') +
        ` · 外键级联 ${fkEnforced ? '生效' : '未生效'}`);
    } catch (e) {
      this.addCheck('数据库建表', false, Logger.errText(e as Object));
    }
  }

  /** 3) Preferences 读写一致性 */
  private async checkSettings(): Promise<void> {
    try {
      const settings = SettingsService.getInstance();
      const original: number = settings.getNumber(SettingsKeys.FONT_SIZE,
        AppConstants.DEFAULT_FONT_SIZE);
      const probe: number = original + 1;
      settings.putNumber(SettingsKeys.FONT_SIZE, probe);
      await settings.flushNow();
      const readBack: number = settings.getNumber(SettingsKeys.FONT_SIZE, -1);
      settings.putNumber(SettingsKeys.FONT_SIZE, original);
      await settings.flushNow();

      const ok: boolean = readBack === probe;
      this.addCheck('设置读写', ok,
        ok ? `font_size 写入 ${probe} 读回 ${readBack}，已恢复为 ${original}`
          : `写入 ${probe} 但读回 ${readBack}`);
    } catch (e) {
      this.addCheck('设置读写', false, Logger.errText(e as Object));
    }
  }

  /** 4) 多字节解码 + 字节长度计算（纯内存） */
  private checkByteLengthAndDecoder(): void {
    const label: string = '多字节解码与字节长度';
    try {
      const utf8Text: string = EncodingDetector.decodeAll(new Uint8Array(PROBE_UTF8), Encodings.UTF8);
      const gbkText: string = EncodingDetector.decodeAll(new Uint8Array(PROBE_GBK), Encodings.GBK);
      if (utf8Text !== PROBE_TEXT || gbkText !== PROBE_TEXT) {
        this.addCheck(label, false,
          `解码不符\n期望：${JSON.stringify(PROBE_TEXT)}\n` +
          `utf8：${JSON.stringify(utf8Text)}\ngbk：${JSON.stringify(gbkText)}`);
        return;
      }
      const utf8Len: number = ByteLength.of(PROBE_TEXT, Encodings.UTF8);
      const gbkLen: number = ByteLength.of(PROBE_TEXT, Encodings.GBK);
      if (utf8Len !== PROBE_UTF8.length || gbkLen !== PROBE_GBK.length) {
        this.addCheck(label, false,
          `字节长度算错：utf8 期望 ${PROBE_UTF8.length} 实际 ${utf8Len}；` +
          `gb18030 期望 ${PROBE_GBK.length} 实际 ${gbkLen}`);
        return;
      }
      this.addCheck(label, true,
        `utf-8 一致/字节${utf8Len} · gb18030 一致/字节${gbkLen} · 汉字按 2 字节计`);
    } catch (e) {
      this.addCheck(label, false, Logger.errText(e as Object));
    }
  }

  /** 5) 文件链路：写样本 → 探测 → 分章 → 按偏移反查 → 逐字符比对 */
  private async checkEncodingAndParser(encoding: string, fileName: string): Promise<void> {
    const label: string = `文件链路与分章(${encoding})`;
    let absolutePath: string = '';
    try {
      const relativePath: string = `${AppConstants.DIR_BOOKS}/${fileName}`;
      absolutePath = PathUtil.toAbsolute(relativePath);
      PathUtil.ensureDir(PathUtil.booksDir());

      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(SAMPLE_TEXT);
      const file = fs.openSync(absolutePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, bytes.buffer.slice(0, bytes.length));
      fs.closeSync(file);

      const writtenSize: number = PathUtil.fileSize(relativePath);
      if (writtenSize !== bytes.length) {
        this.addCheck(label, false, `样本写入不完整：期望 ${bytes.length} 实际 ${writtenSize}`);
        return;
      }

      const source = RawFileSource.open(absolutePath);
      try {
        const detection: DetectionResult = EncodingDetector.detect(source);
        const parsed: ParseResult = ChapterParser.parse(source, encoding);
        if (parsed.chapters.length !== EXPECTED_CHAPTERS.length) {
          this.addCheck(label, false,
            `期望 ${EXPECTED_CHAPTERS.length} 章，实际 ${parsed.chapters.length} 章（rule=${parsed.rule}）`);
          return;
        }
        for (let i = 0; i < parsed.chapters.length; i++) {
          const c: ParsedChapter = parsed.chapters[i];
          if (c.startOffset < 0 || c.startOffset >= writtenSize) {
            this.addCheck(label, false, `第 ${i + 1} 章 startOffset=${c.startOffset} 越界`);
            return;
          }
          if (c.endOffset !== null && c.endOffset <= c.startOffset) {
            this.addCheck(label, false, `第 ${i + 1} 章区间非法`);
            return;
          }
          if (i > 0 && c.startOffset < parsed.chapters[i - 1].startOffset) {
            this.addCheck(label, false, `第 ${i + 1} 章 startOffset 回退`);
            return;
          }
        }

        const reader = new ChapterReadService(source, encoding);
        let offsetText: string = '';
        for (let i = 0; i < parsed.chapters.length; i++) {
          const c: ParsedChapter = parsed.chapters[i];
          const text: string = reader.decodeChapter(c.startOffset, c.endOffset, null);
          if (text !== EXPECTED_CHAPTERS[i]) {
            this.addCheck(label, false,
              `第 ${i + 1} 章不符\n期望：${JSON.stringify(EXPECTED_CHAPTERS[i])}\n` +
              `实际：${JSON.stringify(text)}`);
            reader.dispose();
            return;
          }
          const endText: string = c.endOffset === null ? 'eof' : `${c.endOffset}`;
          offsetText += (i > 0 ? ' , ' : '') + `${c.startOffset}-${endText}`;
        }
        const again: string = reader.decodeChapter(
          parsed.chapters[0].startOffset, parsed.chapters[0].endOffset, null);
        const cacheOk: boolean = again === EXPECTED_CHAPTERS[0] && reader.getCacheSize() > 0;

        this.addCheck(label, detection.encoding === encoding && cacheOk,
          `探测=${detection.encoding}(conf=${detection.confidence}) · rule=${parsed.rule} · ` +
          `偏移 [${offsetText}] · 逐字符比对通过 · 缓存${cacheOk ? '命中' : '未命中'}`);
        reader.dispose();
      } finally {
        source.close();
      }
    } catch (e) {
      this.addCheck(label, false, Logger.errText(e as Object));
    } finally {
      try {
        if (absolutePath.length > 0 && fs.accessSync(absolutePath)) {
          fs.unlinkSync(absolutePath);
        }
      } catch (cleanupErr) {
        // 忽略
      }
    }
  }

  /** 6) 数据层全链路 */
  private async checkDataPipeline(): Promise<void> {
    const label: string = '数据层全链路';
    let bookId: number = 0;
    let absolutePath: string = '';

    try {
      const uuid: string = `selftest-${Date.now()}`;
      const relativePath: string = PathUtil.bookRelativePath(uuid);
      absolutePath = PathUtil.toAbsolute(relativePath);
      PathUtil.ensureDir(PathUtil.booksDir());

      const encoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(SAMPLE_TEXT);
      const file = fs.openSync(absolutePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, bytes.buffer.slice(0, bytes.length));
      fs.closeSync(file);

      const preparation = new ImportPreparation();
      preparation.uri = `file://selftest/${uuid}.txt`;
      preparation.uuid = uuid;
      preparation.relativePath = relativePath;
      preparation.fileSize = bytes.length;
      preparation.fileHash = `selftest-hash-${uuid}`;
      preparation.encoding = Encodings.UTF8;
      const parseResult: ImportResult = ImportService.parseInto(preparation, Encodings.UTF8);
      if (parseResult.outcome !== ImportOutcome.SUCCESS) {
        this.addCheck(label, false, `解析失败：${parseResult.error}`);
        return;
      }

      const commitResult: ImportResult = await ImportService.commit(preparation, '自检样本');
      if (commitResult.outcome !== ImportOutcome.SUCCESS || commitResult.bookId <= 0) {
        this.addCheck(label, false, `入库失败：${commitResult.error}`);
        return;
      }
      bookId = commitResult.bookId;

      const shelf: Book[] = await BookRepository.listShelf(BookSort.LAST_READ, null);
      let found: Book | null = null;
      for (const b of shelf) {
        if (b.id === bookId) {
          found = b;
          break;
        }
      }
      if (found === null || found.totalChapters !== EXPECTED_CHAPTERS.length) {
        this.addCheck(label, false, '入库后书架里查不到这本书或章节数不符');
        return;
      }

      const chapters: Chapter[] = await ChapterRepository.listByBook(bookId);
      if (chapters.length !== EXPECTED_CHAPTERS.length) {
        this.addCheck(label, false, `目录 ${chapters.length} 章，期望 ${EXPECTED_CHAPTERS.length} 章`);
        return;
      }

      const source = RawFileSource.tryOpen(absolutePath);
      if (source === null) {
        this.addCheck(label, false, '无法打开沙箱文件读取正文');
        return;
      }
      let firstChapterText: string = '';
      try {
        const reader = new ChapterReadService(source, Encodings.UTF8);
        for (let i = 0; i < chapters.length; i++) {
          const text: string = reader.decodeChapter(
            chapters[i].startOffset, chapters[i].endOffset, null);
          if (text !== EXPECTED_CHAPTERS[i]) {
            this.addCheck(label, false, `第 ${i + 1} 章内容与偏移不符`);
            reader.dispose();
            return;
          }
        }
        firstChapterText = reader.decodeChapter(
          chapters[0].startOffset, chapters[0].endOffset, null);
        reader.dispose();
      } finally {
        source.close();
      }

      const settings = SettingsService.getInstance().loadReaderSettings();
      const layoutKey: string = PaginationService.buildLayoutKey(settings, 360, 640);
      const breaks: number[] = PaginationService.computeBreaks(
        firstChapterText, settings, 360, 640);
      if (breaks.length === 0 || breaks[0] !== 0) {
        this.addCheck(label, false, '分页断点非法');
        return;
      }
      // 缓存第 0 章：进度与恢复必须落在同一章，断言才自洽
      await PageCacheRepository.save(bookId, 0, layoutKey, breaks);
      const cachedBreaks: number[] = await PageCacheRepository.getBreaks(bookId, 0, layoutKey);
      if (cachedBreaks.length !== breaks.length
        || PaginationService.locatePage(cachedBreaks, 0) !== 0) {
        this.addCheck(label, false, '分页缓存读回不一致');
        return;
      }

      const progress = new ProgressService(bookId);
      progress.updatePosition(0, 0, 0.1);
      progress.markActive();
      await progress.flush(true);
      const reloaded = await BookRepository.getById(bookId);
      if (reloaded === null || reloaded.lastChapterIndex !== 0) {
        this.addCheck(label, false, '进度落库后读回不符');
        return;
      }
      const restored: RestoredPosition = await ProgressService.restore(reloaded, layoutKey);
      if (restored.chapterIndex !== 0 || !restored.cacheHit) {
        this.addCheck(label, false,
          `恢复位置不符：chapterIndex=${restored.chapterIndex} cacheHit=${restored.cacheHit}`);
        return;
      }

      await StatsService.submit(bookId, 12);
      await StatsService.submit(bookId, 8);
      const bookSeconds: number = await StatsService.bookDuration(bookId);
      if (bookSeconds !== 20) {
        this.addCheck(label, false, `统计累加不符：期望 20 秒，实际 ${bookSeconds}`);
        return;
      }

      const lookup = await BookRepository.findByHash(preparation.fileHash);
      if (lookup.status !== HashLookup.ACTIVE) {
        this.addCheck(label, false, `判重未命中在架书（status=${lookup.status}）`);
        return;
      }

      const bookmarkId: number = await AnnotationRepository.addBookmark(bookId, 1, 5);
      if (bookmarkId <= 0) {
        this.addCheck(label, false, '新增书签失败（冗余列可能未填充）');
        return;
      }

      await BookRepository.softDelete(bookId);
      if ((await BookRepository.getById(bookId)) !== null) {
        this.addCheck(label, false, '软删除后仍能查到（deleted 过滤失效）');
        return;
      }
      await BookRepository.restore(bookId);

      await BookRepository.hardDelete(bookId);
      const orphanChapters: number = await ChapterRepository.countByBook(bookId);
      const orphanCache: number = await PageCacheRepository.countByBook(bookId);
      const orphanAnnotations: number = await AnnotationRepository.countByBook(
        bookId, AppConstants.ANNOTATION_ALL);
      if (orphanChapters !== 0 || orphanCache !== 0 || orphanAnnotations !== 0) {
        this.addCheck(label, false,
          `级联删除未生效：章节 ${orphanChapters} / 缓存 ${orphanCache} / 标注 ${orphanAnnotations}`);
        return;
      }
      bookId = 0;

      this.addCheck(label, true,
        `导入3章·偏移一致·分页${breaks.length}页·进度恢复·统计20s·判重命中·书签·软删恢复·级联清理`);
    } catch (e) {
      this.addCheck(label, false, Logger.errText(e as Object));
    } finally {
      if (bookId > 0) {
        try {
          await BookRepository.hardDelete(bookId);
        } catch (cleanupErr) {
          // 忽略
        }
      }
      try {
        if (absolutePath.length > 0 && fs.accessSync(absolutePath)) {
          fs.unlinkSync(absolutePath);
        }
      } catch (cleanupErr) {
        // 忽略
      }
    }
  }

  /**
   * 7) A/B/C/D 对照：定位"事务内取主键"的可用写法。
   *
   * 这四组是铁律 4 的直接证据，保留下来防止将来有人改回错误写法：
   *   A 事务外·仓储 insert         → 可用
   *   B 事务内·仓储 insert         → 已修复为 typed insert，可用
   *   C 事务内·typed insert        → 可用（当前采用）
   *   D 事务内·executeSql+rowid    → 不可用（保留为反面记录）
   */
  private async probeTransactionInsert(): Promise<void> {
    const db = RdbHelper.getInstance();
    const store = db.getStore();
    const now: number = Date.now();

    // A 组：事务外，走仓储
    const uuidA: string = nextUuid('tx-a');
    try {
      const idA: number = await BookRepository.insert(SelfCheckPage.buildProbeBook(uuidA, now));
      this.addCheck('A 事务外·仓储 insert', idA > 0, `返回 id=${idA}`);
    } catch (e) {
      this.addCheck('A 事务外·仓储 insert', false, `抛错：${Logger.errText(e as Object)}`);
    } finally {
      await this.safeCleanup(uuidA);
    }

    // B 组：事务内，走仓储（导入流程走的就是这条路）
    const uuidB: string = nextUuid('tx-b');
    try {
      let idInner: number = -1;
      await db.withTransaction<void>(async () => {
        idInner = await BookRepository.insert(SelfCheckPage.buildProbeBook(uuidB, now));
      });
      const idAfter: number = await db.queryNumber(
        `SELECT id FROM ${DbConstants.TABLE_BOOK} WHERE uuid = ?`, [uuidB], -1);
      this.addCheck('B 事务内·仓储 insert', idInner > 0 && idAfter > 0,
        `事务内返回=${idInner}，提交后查=${idAfter}`);
    } catch (e) {
      this.addCheck('B 事务内·仓储 insert', false, `抛错：${Logger.errText(e as Object)}`);
    } finally {
      await this.safeCleanup(uuidB);
    }

    // C 组：事务内，typed insert（当前采用的写法）
    const uuidC: string = nextUuid('tx-c');
    try {
      let rowId: number = -1;
      await db.withTransaction<void>(async () => {
        const bucket: relationalStore.ValuesBucket = {
          'uuid': uuidC, 'title': '探测C', 'file_path': 'books/probe-c.txt',
          'format': 'txt', 'added_at': now, 'updated_at': now
        };
        rowId = await store.insert(DbConstants.TABLE_BOOK, bucket);
      });
      this.addCheck('C 事务内·typed insert', rowId > 0, `rowId=${rowId}（不需要回查）`);
    } catch (e) {
      this.addCheck('C 事务内·typed insert', false, `抛错：${Logger.errText(e as Object)}`);
    } finally {
      await this.safeCleanup(uuidC);
    }

    // D 组：事务内 executeSql + last_insert_rowid —— 期望失败的记录
    const uuidD: string = nextUuid('tx-d');
    try {
      let rowId: number = -1;
      await db.withTransaction<void>(async () => {
        await store.executeSql(
          `INSERT INTO ${DbConstants.TABLE_BOOK} (uuid, title, file_path, format, added_at, updated_at) ` +
          `VALUES (?,?,?,?,?,?)`,
          [uuidD, '探测D', 'books/probe-d.txt', 'txt', now, now]);
        rowId = await db.queryNumber(`SELECT last_insert_rowid()`, [], -1);
      });
      const afterCommit: number = await db.queryNumber(
        `SELECT COUNT(*) FROM ${DbConstants.TABLE_BOOK} WHERE uuid = ?`, [uuidD], -1);
      this.addCheck('D 事务内·executeSql + rowid', rowId <= 0 && afterCommit === 1,
        `last_insert_rowid=${rowId}（事务内取不到）· 提交后行数=${afterCommit}` +
        ` → 已确认此路不可用，取主键必须用 typed insert`);
    } catch (e) {
      this.addCheck('D 事务内·executeSql + rowid', false, `抛错：${Logger.errText(e as Object)}`);
    } finally {
      await this.safeCleanup(uuidD);
    }
  }

  private static buildProbeBook(uuid: string, now: number): Book {
    const book = new Book();
    book.uuid = uuid;
    book.title = '定向探测书';
    book.filePath = 'books/probe.txt';
    book.format = AppConstants.FORMAT_TXT;
    book.encoding = Encodings.UTF8;
    book.fileSize = 1024;
    book.fileHash = `probe-hash-${uuid}`;
    book.totalChapters = 3;
    book.wordCount = 500;
    book.addedAt = now;
    book.updatedAt = now;
    book.parseStatus = AppConstants.PARSE_SUCCESS;
    book.parseRule = 'probe';
    book.lastChapterIndex = -1;
    return book;
  }

  private async safeCleanup(uuid: string): Promise<void> {
    try {
      await RdbHelper.getInstance().getStore().executeSql(
        `DELETE FROM ${DbConstants.TABLE_BOOK} WHERE uuid = ?`, [uuid]);
    } catch (e) {
      // 忽略
    }
  }
}
