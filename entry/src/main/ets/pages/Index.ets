import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { RdbHelper } from '../data/database/RdbHelper';
import { SettingsService } from '../data/service/SettingsService';
import { ChapterReadService } from '../data/service/ChapterReadService';
import { RawFileSource } from '../data/source/RawFileSource';
import { PathUtil } from '../common/utils/PathUtil';
import { EncodingDetector, DetectionResult, Encodings } from '../common/utils/EncodingDetector';
import { ChapterParser, ParseResult, ParsedChapter } from '../common/utils/ChapterParser';
import { ByteLength } from '../common/utils/ByteLength';
import { Logger } from '../common/utils/Logger';
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
 * 用于验证分章与字节偏移的测试文本。
 *
 * 结构：作品行 + 前言段 + 三章正文。
 * 前言段刻意小于 200 字节，因此【不会】生成"前言"章节 —— 期望正好解析出 3 章。
 * 每章正文都用 \n\n 结尾，便于逐字符比对。
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

// ============================================================================
// 内存字节校验用的样本
//
// 下面两组字节是【手工核算】过的同一段文本，分别按 UTF-8 与 GB18030 编码。
// 用途：验证 StringDecoder 的多字节解码，以及 ByteLength 的字节长度计算。
//
// 为什么不写成文件：util.TextEncoder 只做 UTF-8（其 encoding 参数无效，
// 且 SDK 中不存在的 util.StringEncoder），无法用它生成 GB18030 字节；
// 写死字节数组才能真正压到多字节路径。
// ============================================================================

/** 样本文本：第一章 风起 + 正文「这是正文。行二。」 */
const PROBE_TEXT: string = '第一章 风起\n这是正文。行二。';

/** 上述文本的 UTF-8 字节（共 61 字节） */
const PROBE_UTF8: number[] = [
  0xE7, 0xAC, 0xAC, 0xE4, 0xB8, 0x80, 0xE7, 0xAB, 0xA0, 0x20, // 第一章␣
  0xE9, 0xA3, 0x8E, 0xE8, 0xB5, 0xB7, 0x0A,                     // 风起\n
  0xE8, 0xBF, 0x99, 0xE6, 0x98, 0xAF, 0xE6, 0xAD, 0xA3, 0xE6, 0x96, 0x87, // 这是正文
  0xE3, 0x80, 0x82,                                             // 。
  0xE8, 0xA1, 0x8C, 0xE4, 0xBA, 0x8C,                           // 行二
  0xE3, 0x80, 0x82                                              // 。
];

/** 同一文本的 GB18030 字节（共 28 字节） */
const PROBE_GBK: number[] = [
  0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x20, // 第一章␣
  0xB7, 0xE7, 0xC6, 0xF0, 0x0A,             // 风起\n
  0xD5, 0xE2, 0xCA, 0xC7, 0xD5, 0xFD, 0xCE, 0xC4, 0xA1, 0xA3, // 这是正文。
  0xD0, 0xD0, 0xB6, 0xFE, 0xA1, 0xA3        // 行二。
];

/**
 * 临时自检页 —— 验证阶段 ① + 阶段 ② 的底座是否可靠。
 *
 * 验证通过后，本页应被 Navigation 路由容器替换（见设计文档 8.1）。
 */
@Entry
@Component
struct Index {
  @State checks: CheckItem[] = [];
  @State running: boolean = false;
  @State summary: string = '正在自检…';

  aboutToAppear(): void {
    this.runAll();
  }

  build() {
    Column({ space: 12 }) {
      Column({ space: 4 }) {
        Text('阅读器 · 底座自检')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .textAlign(TextAlign.Start)
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

  private async runAll(): Promise<void> {
    this.running = true;
    this.checks = [];
    this.summary = '正在自检…';

    this.checkPath();
    await this.checkDatabase();
    await this.checkSettings();
    this.checkByteLengthAndDecoder();
    // 注意：util.TextEncoder 只能产出 UTF-8，所以文件链路只测 UTF-8；
    // GB18030 的字节长度正确性由上一项用写死的字节数组覆盖。
    await this.checkEncodingAndParser(Encodings.UTF8, 'probe-utf8.txt');

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
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      PathUtil.init(context);
      this.addCheck('沙箱路径', PathUtil.isReady(), `filesDir = ${PathUtil.getFilesDir()}`);
    } catch (e) {
      this.addCheck('沙箱路径', false, Logger.errText(e as Object));
    }
  }

  /** 期望存在的索引（与 DbSchema.CREATE_INDEX_SQL 一一对应） */
  private static readonly EXPECTED_INDEXES: string[] = [
    'uq_book_uuid', 'uq_book_hash', 'idx_book_shelf', 'idx_book_group', 'idx_book_status',
    'idx_chapter_title',
    'idx_annotation_book', 'idx_annotation_chapter', 'idx_annotation_type',
    'uq_group_name', 'idx_group_sort',
    'uq_stats_book_date', 'idx_stats_date',
    'uq_page_cache', 'idx_page_cache_book'
  ];

  /** 2) 数据库建表 + 索引 + 外键级联是否真的生效 */
  private async checkDatabase(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await RdbHelper.init(context);
      const db = RdbHelper.getInstance();

      const tables: string[] = [
        DbConstants.TABLE_BOOK, DbConstants.TABLE_CHAPTER, DbConstants.TABLE_ANNOTATION,
        DbConstants.TABLE_BOOK_GROUP, DbConstants.TABLE_DAILY_STATS, DbConstants.TABLE_PAGE_CACHE
      ];
      const missingTables: string[] = [];
      for (const t of tables) {
        const exists: boolean = await db.hasTable(t);
        if (!exists) {
          missingTables.push(t);
        }
      }
      if (missingTables.length > 0) {
        this.addCheck('数据库建表', false, `缺少表：${missingTables.join(', ')}`);
        return;
      }

      // 索引：逐个核对，缺哪条直接点名（部分索引在旧版 SQLite 上会创建失败）
      const actual: string[] = await db.listIndexNames();
      const missingIndexes: string[] = [];
      for (const expected of Index.EXPECTED_INDEXES) {
        let found: boolean = false;
        for (const name of actual) {
          if (name === expected) {
            found = true;
            break;
          }
        }
        if (!found) {
          missingIndexes.push(expected);
        }
      }

      // 外键：用"插入孤儿行应当失败"来确定性验证（PRAGMA 查询结果不可靠）
      const fkEnforced: boolean = await db.verifyForeignKeyEnforced();

      const ok: boolean = missingIndexes.length === 0 && fkEnforced;
      this.addCheck('数据库建表', ok,
        `6 张表 · 索引 ${actual.length}/${Index.EXPECTED_INDEXES.length} 条` +
        (missingIndexes.length > 0 ? ` 缺:${missingIndexes.join(',')}` : '') +
        ` · 外键级联 ${fkEnforced ? '生效' : '未生效(删书会留下孤儿章节)'}`);
    } catch (e) {
      this.addCheck('数据库建表', false, Logger.errText(e as Object));
    }
  }

  /** 3) Preferences 读写一致性 */
  private async checkSettings(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await SettingsService.init(context);
      const settings = SettingsService.getInstance();

      const original: number = settings.getNumber(SettingsKeys.FONT_SIZE,
        AppConstants.DEFAULT_FONT_SIZE);
      const probe: number = original + 1;
      settings.putNumber(SettingsKeys.FONT_SIZE, probe);
      await settings.flushNow();
      const readBack: number = settings.getNumber(SettingsKeys.FONT_SIZE, -1);

      // 读回后立即恢复原值，避免污染真实设置
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

  /**
   * 4) 多字节解码 + 字节长度计算（纯内存，不依赖任何编码器）。
   *
   * 同一段文本按 UTF-8(61B) 与 GB18030(28B) 两组手工核算的字节解码，要求：
   *  - 两种编码解码出的字符串完全一致；
   *  - ByteLength.of 分别返回 61 与 28。
   *
   * 这一项专门用来挡住 "TextEncoder 只做 UTF-8" 造成的字节长度算错 ——
   * 若有人再改回用 TextEncoder 计算，GB18030 那半边会立刻变红。
   */
  private checkByteLengthAndDecoder(): void {
    const label: string = '多字节解码与字节长度';
    try {
      const utf8Text: string = EncodingDetector.decodeAll(new Uint8Array(PROBE_UTF8), Encodings.UTF8);
      const gbkText: string = EncodingDetector.decodeAll(new Uint8Array(PROBE_GBK), Encodings.GBK);

      if (utf8Text !== PROBE_TEXT) {
        this.addCheck(label, false,
          `UTF-8 解码不符\n期望：${JSON.stringify(PROBE_TEXT)}\n实际：${JSON.stringify(utf8Text)}`);
        return;
      }
      if (gbkText !== PROBE_TEXT) {
        this.addCheck(label, false,
          `GB18030 解码不符（StringDecoder 多字节路径有问题）\n` +
          `期望：${JSON.stringify(PROBE_TEXT)}\n实际：${JSON.stringify(gbkText)}`);
        return;
      }

      const utf8Len: number = ByteLength.of(PROBE_TEXT, Encodings.UTF8);
      const gbkLen: number = ByteLength.of(PROBE_TEXT, Encodings.GBK);
      const gb18030Len: number = ByteLength.of(PROBE_TEXT, Encodings.GB18030);

      if (utf8Len !== PROBE_UTF8.length) {
        this.addCheck(label, false,
          `UTF-8 字节长度算错：期望 ${PROBE_UTF8.length}，实际 ${utf8Len}`);
        return;
      }
      if (gbkLen !== PROBE_GBK.length || gb18030Len !== PROBE_GBK.length) {
        this.addCheck(label, false,
          `GB18030 字节长度算错：期望 ${PROBE_GBK.length}，实际 gbk=${gbkLen} gb18030=${gb18030Len}`);
        return;
      }

      this.addCheck(label, true,
        `utf-8 解码一致/字节${utf8Len} · gb18030 解码一致/字节${gbkLen} · ` +
        `汉字按 2 字节计（若误用 TextEncoder 会算成 3 字节）`);
    } catch (e) {
      this.addCheck(label, false, Logger.errText(e as Object));
    }
  }

  /**
   * 5) 端到端验证：写样本文件 → 编码探测 → 分章 → 按字节偏移反查原文 → 逐字符比对。
   *
   * 这是最关键的一项：只要字节偏移差一个字节（例如 \r\n 被当成 \n 计数），
   * 或者多字节字符跨块时游标算错，比对就会失败。
   *
   * 只用 UTF-8：util.TextEncoder 无法产出其它编码的字节。
   */
  private async checkEncodingAndParser(encoding: string, fileName: string): Promise<void> {
    const label: string = `文件链路与分章(${encoding})`;
    let absolutePath: string = '';
    try {
      const relativePath: string = `${AppConstants.DIR_BOOKS}/${fileName}`;
      absolutePath = PathUtil.toAbsolute(relativePath);
      PathUtil.ensureDir(PathUtil.booksDir());

      // ---- 写入样本文件
      // 注意：TextEncoder 只做 UTF-8，其 encoding 参数无效（SDK 中也没有 StringEncoder）。
      // 因此本方法只能测 UTF-8；GB18030 的字节长度由上一项覆盖。
      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(SAMPLE_TEXT);
      const file = fs.openSync(absolutePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, bytes.buffer.slice(0, bytes.length));
      fs.closeSync(file);

      const writtenSize: number = PathUtil.fileSize(relativePath);
      if (writtenSize !== bytes.length) {
        this.addCheck(label, false, `样本写入不完整：期望 ${bytes.length} 字节，实际 ${writtenSize}`);
        return;
      }

      const source = RawFileSource.open(absolutePath);
      try {
        // ---- 编码探测
        const detection: DetectionResult = EncodingDetector.detect(source);
        const detectOk: boolean = detection.encoding === encoding;

        // ---- 分章
        const parsed: ParseResult = ChapterParser.parse(source, encoding);
        if (parsed.chapters.length !== EXPECTED_CHAPTERS.length) {
          this.addCheck(label, false,
            `期望 ${EXPECTED_CHAPTERS.length} 章，实际 ${parsed.chapters.length} 章` +
            `（rule=${parsed.rule}，字节数=${writtenSize}）`);
          return;
        }

        // ---- 校验字节偏移的单调性与边界
        for (let i = 0; i < parsed.chapters.length; i++) {
          const c: ParsedChapter = parsed.chapters[i];
          if (c.startOffset < 0 || c.startOffset >= writtenSize) {
            this.addCheck(label, false, `第 ${i + 1} 章 startOffset=${c.startOffset} 越界`);
            return;
          }
          if (c.endOffset !== null && c.endOffset <= c.startOffset) {
            this.addCheck(label, false,
              `第 ${i + 1} 章区间非法：${c.startOffset}~${c.endOffset}`);
            return;
          }
          if (i > 0 && c.startOffset < parsed.chapters[i - 1].startOffset) {
            this.addCheck(label, false, `第 ${i + 1} 章 startOffset 回退，偏移计算有误`);
            return;
          }
        }

        // ---- 按字节偏移反查每一章，与预期逐字符比对
        // （走 ChapterReadService，顺带验证随机读与 LRU；它会接管 source 的释放）
        const reader = new ChapterReadService(source, encoding);
        let offsetText: string = '';
        for (let i = 0; i < parsed.chapters.length; i++) {
          const c: ParsedChapter = parsed.chapters[i];
          const text: string = reader.decodeChapter(c.startOffset, c.endOffset, null);
          if (text !== EXPECTED_CHAPTERS[i]) {
            this.addCheck(label, false,
              `第 ${i + 1} 章内容不匹配\n期望：${JSON.stringify(EXPECTED_CHAPTERS[i])}\n` +
              `实际：${JSON.stringify(text)}`);
            reader.dispose();
            return;
          }
          const endText: string = c.endOffset === null ? 'eof' : `${c.endOffset}`;
          offsetText += (i > 0 ? ' , ' : '') + `${c.startOffset}-${endText}`;
        }

        // ---- 缓存命中检查：同章再读一次应命中 LRU
        const again: string = reader.decodeChapter(
          parsed.chapters[0].startOffset, parsed.chapters[0].endOffset, null);
        const cacheOk: boolean = again === EXPECTED_CHAPTERS[0] && reader.getCacheSize() > 0;

        this.addCheck(label, detectOk && cacheOk,
          `探测=${detection.encoding}(conf=${detection.confidence}) · rule=${parsed.rule} · ` +
          `${parsed.chapters.length} 章偏移 [${offsetText}] · 逐字符比对通过 · ` +
          `缓存${cacheOk ? '命中' : '未命中'}(${reader.getCacheSize()})`);
        reader.dispose();
      } finally {
        // reader.dispose() 已关闭 source；这里只在异常提前返回时兜底
        source.close();
      }
    } catch (e) {
      this.addCheck(label, false, Logger.errText(e as Object));
    } finally {
      // 清理样本文件，避免污染沙箱
      try {
        if (absolutePath.length > 0 && fs.accessSync(absolutePath)) {
          fs.unlinkSync(absolutePath);
        }
      } catch (cleanupErr) {
        // 清理失败不影响自检结论
      }
    }
  }
}
