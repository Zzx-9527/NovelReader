/**
 * 业务常量。
 * 所有"魔法数字"集中在此，禁止在业务代码里散落字面量。
 *
 * 详见 docs/小说阅读器设计文档.md
 */
export class AppConstants {
  // ---------------------------------------------------------------- 解析状态
  /** book.parse_status：0待解析 */
  static readonly PARSE_PENDING: number = 0;
  /** book.parse_status：1解析中 */
  static readonly PARSE_RUNNING: number = 1;
  /** book.parse_status：2成功 */
  static readonly PARSE_SUCCESS: number = 2;
  /** book.parse_status：3失败（含"文件丢失"） */
  static readonly PARSE_FAILED: number = 3;

  // ---------------------------------------------------------------- 阅读状态
  static readonly READ_STATUS_UNREAD: number = 0;
  static readonly READ_STATUS_READING: number = 1;
  static readonly READ_STATUS_FINISHED: number = 2;

  // ---------------------------------------------------------------- 标注类型
  static readonly ANNOTATION_BOOKMARK: number = 1;
  static readonly ANNOTATION_HIGHLIGHT: number = 2;
  static readonly ANNOTATION_NOTE: number = 3;
  /** 查询全部类型时传给 Repository 的哨兵值 */
  static readonly ANNOTATION_ALL: number = 0;

  // ---------------------------------------------------------------- 书籍格式
  static readonly FORMAT_TXT: string = 'txt';
  static readonly FORMAT_EPUB: string = 'epub';

  // ---------------------------------------------------------------- 文件与目录
  static readonly DIR_BOOKS: string = 'books';
  static readonly DIR_COVERS: string = 'covers';
  static readonly DIR_BACKUP: string = 'backup';

  static readonly EXT_TXT: string = '.txt';
  static readonly EXT_EPUB: string = '.epub';
  static readonly EXT_JPG: string = '.jpg';

  // ---------------------------------------------------------------- 性能参数
  /** 章节批量写入的行数 */
  static readonly CHAPTER_BATCH_SIZE: number = 500;
  /** 解析时每次读文件的字节数：1 MiB */
  static readonly READ_CHUNK_BYTES: number = 1024 * 1024;
  /** 计算哈希时的块大小：512 KiB */
  static readonly HASH_CHUNK_BYTES: number = 512 * 1024;
  /** 编码探测取样字节数：4 MiB */
  static readonly ENCODING_SAMPLE_BYTES: number = 4 * 1024 * 1024;
  /** 单章解码的默认上限：2 MiB（防止"最后一章"把整本书读进内存） */
  static readonly DEFAULT_CHAPTER_MAX_BYTES: number = 2 * 1024 * 1024;
  /** 章节正文 LRU 缓存的章节数 */
  static readonly CHAPTER_CACHE_SIZE: number = 5;

  // ---------------------------------------------------------------- 时间参数
  /** 无操作超过该毫秒数则暂停阅读计时（5 分钟） */
  static readonly IDLE_TIMEOUT_MS: number = 5 * 60 * 1000;
  /** 阅读进度落库节流（10 秒） */
  static readonly PROGRESS_FLUSH_INTERVAL_MS: number = 10 * 1000;
  /** 分页重算防抖（300ms） */
  static readonly PAGINATION_DEBOUNCE_MS: number = 300;
  /** 设置落盘合并窗口（500ms） */
  static readonly SETTINGS_FLUSH_DELAY_MS: number = 500;
  /**
   * 阅读页左右滑动翻页的最小水平位移（vp）。
   *
   * 不能取太小：手指点按时本来就带几个 vp 的抖动，
   * 阈值太小会把"点右侧翻下一页"识别成滑动，一次操作翻两页。
   */
  static readonly PAGE_SWIPE_MIN_DISTANCE: number = 40;

  // ---------------------------------------------------------------- 分章
  /** 首章之前超过这么多字节才补一条"前言" */
  static readonly PREFACE_MIN_BYTES: number = 200;
  /** 至少命中多少条章节标记才认为规则可靠 */
  static readonly MIN_CHAPTER_MARKERS: number = 3;
  /** 章节标题行的最大长度（超过必然不是标题） */
  static readonly MAX_TITLE_LINE_LENGTH: number = 60;
  /** 兜底切分时每章约多少个字符 */
  static readonly FALLBACK_CHARS_PER_CHAPTER: number = 8000;

  // ---------------------------------------------------------------- 默认排版
  static readonly DEFAULT_FONT_SIZE: number = 18;
  static readonly DEFAULT_LINE_HEIGHT: number = 1.6;
  static readonly DEFAULT_PARAGRAPH_SPACING: number = 0.5;
  static readonly DEFAULT_PAGE_MARGIN: number = 16;
  static readonly DEFAULT_FIRST_LINE_INDENT: number = 2;
}

/** 日志 tag，便于按模块过滤 */
export class LogTag {
  static readonly DB: string = 'RdbHelper';
  static readonly IMPORT: string = 'ImportService';
  static readonly PARSER: string = 'ChapterParser';
  static readonly ENCODING: string = 'EncodingDetector';
  static readonly SETTINGS: string = 'SettingsService';
  static readonly REPO: string = 'Repository';
  static readonly READ: string = 'ChapterReadService';
  static readonly PAGINATION: string = 'PaginationService';
  static readonly PROGRESS: string = 'ProgressService';
  static readonly STATS: string = 'StatsService';
}
