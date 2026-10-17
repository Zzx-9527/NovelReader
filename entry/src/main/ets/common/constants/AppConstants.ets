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
  /**
   * 划线的默认颜色（hex 字符串）。
   *
   * ⚠️ 存的是**颜色值本身**而不是"第几号颜色"：数据库里 `color` 是 TEXT，
   * 存颜色值可以让将来支持自定义颜色时**不用迁移数据**。
   *
   * ⚠️ 用暖黄（半透明感的高亮底），不是主题色：划线是"标出正文"，
   * 铺在文字**底下**，用蓝/绿这类彩色会与正文对比度打架、读起来发花。
   */
  static readonly HIGHLIGHT_DEFAULT_COLOR: string = '#FFF2A8';

  /**
   * 划线底纹的圆角（vp）。
   *
   * ⚠️ 取一个很小的值（2）而不是 0 或全圆角：底色是**逐行**铺在文字后面的，
   * 行与行之间会被行距切开；圆角 0 时每一行都是一段硬边色块，堆起来像表格；
   * 圆角太大（≥4）又会在短行上把色块缩成一个胶囊，看着像按钮。
   * 2 足以去掉硬角，又保持"这是一段连续的标线"的观感。
   */
  static readonly HIGHLIGHT_RADIUS: number = 2;

  /**
   * 从「跟随系统」切到「手动」亮度时的起始值（0~1）。
   *
   * ⚠️ 必须有这么一个值：`ReaderSettings.brightness` 用 `-1` 表示跟随系统，
   * 而滑块只能表达 0~1。切到手动时若沿用 `-1`，滑块会拿到一个非法值。
   *
   * 取 0.5 而不是 1.0 或 0.0：**切换那一瞬间屏幕观感不该突变** ——
   * 0.5 接近多数设备的默认亮度，用户切过去只觉得"可以调了"，
   * 而不是"屏幕怎么突然这么亮/这么暗"。
   */
  static readonly DEFAULT_MANUAL_BRIGHTNESS: number = 0.5;

  // ---------------------------------------------------------------- 书籍格式
  /**
   * 只支持 TXT。EPUB 支持已评估并**明确放弃**（用户决策）：
   * 目标用户读网文，书源天然是 TXT；EPUB 的渠道（出版书/公版书）
   * 与实际阅读场景不匹配，为不存在的需求引入 zip/XHTML 解析不值得。
   * 判据：**不为想象中的需求写代码。** 若将来重做，见设计文档的记录。
   */
  static readonly FORMAT_TXT: string = 'txt';

  // ---------------------------------------------------------------- 分组封面
  /**
   * 分组封面的格子数（2×2）。
   *
   * ⚠️ 分组封面是"**用组内书的封面填格子**"（用户明确要求）：
   * 有几本填几格，填满 4 格后**不再变化**。
   * 所以取封面时只需前 4 本 —— 不必把整个组加载进内存。
   *
   * ⚠️ 这个数字同时决定"取几本书"与"画几个格子"，两处必须**同源**：
   * 各写一个 4 就会出现"取了 4 本但画 6 格"这类对不上的情况。
   */
  static readonly GROUP_COVER_SLOTS: number = 4;

  // ---------------------------------------------------------------- 文件与目录
  static readonly DIR_BOOKS: string = 'books';
  static readonly DIR_COVERS: string = 'covers';
  static readonly DIR_BACKUP: string = 'backup';

  static readonly EXT_TXT: string = '.txt';
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
  /**
   * 章末自动衔接下一章后的冷却时间（ms）。
   *
   * 切章过程中还会陆续到达若干次滚动回调，此时"是否滚到底"的判断
   * 用的仍是旧内容的高度 —— 不冷却就会一口气连跳好几章。
   */
  static readonly AUTO_CONTINUE_COOLDOWN_MS: number = 800;
  /**
   * 阅读页"点击"的最大按住时长（ms）。
   *
   * ⚠️ 存在的唯一理由：滚动模式的单击挂在 `parallelGesture(TapGesture)` 上，
   * 而它的语义是"**可与子节点手势同时触发**" —— 长按选中正文后松手时，
   * 这个 Tap 也会触发，于是 `handleReaderTap` 看到有选中就去关菜单，
   * 表现是**选择菜单一闪就消失**（用户实测反馈）。
   *
   * 所以用按住时长区分："按住超过这个阈值 = 长按，不算点击"。
   * 取 400ms：系统长按阈值约 500ms，而正常点击通常 < 250ms，
   * 400ms 落在两者之间，既不会误判慢一点的点击，也能挡住长按。
   */
  static readonly READER_TAP_MAX_MS: number = 400;
  /**
   * 点完系统选择菜单后，等它收起再执行后续动作的延迟（ms）。
   *
   * ⚠️ 为什么要等：系统选择菜单是**系统级浮层**，层级高于应用内任何内容
   * （把弹窗放到应用最顶层也没用）。而它是在自己的后续帧里收起的 ——
   * 我们在 `onMenuItemClick` 里同步弹窗，会被还没收完的菜单压住，
   * 表现是"系统菜单挡住书签弹窗"（用户实测反馈影响观感）。
   *
   * 取 120ms：比菜单收起动画略长，用户基本察觉不到，
   * 但足以避开与系统抢时序。
   */
  static readonly READER_MENU_DISMISS_MS: number = 120;
  /**
   * 滚动模式"恢复阅读位置"的延迟重试（ms）。
   *
   * ⚠️ 为什么需要延迟重试，而不是只靠 `onAreaChange`：
   * 滚动模式的正文是整章一个 `Text`，恢复位置必须在**新内容布局完成后**才能滚
   * （提前滚会按旧内容裁剪，滚到一个错误位置）。而 `onAreaChange` 只在
   * **尺寸真的变了**才触发 —— 于是"同一章内跳到某个书签"这类场景
   * （章节没变、内容高度自然也没变）就**永远不会触发**，位置也就永远恢复不了。
   *
   * 所以换章/跳转后补一次延迟重试，与 `onAreaChange` 两条路都走，
   * 由"取走即清空"的标记保证实际只生效一次。
   *
   * 取 50ms：足够跨过一帧布局（16ms 级），又不至于让用户察觉"过一会儿才跳过去"。
   */
  static readonly READER_SCROLL_RESTORE_DELAY_MS: number = 50;
  /**
   * 滚动位置恢复的**放弃时限**（ms）。
   *
   * ⚠️ 为什么需要它：恢复滚动位置依赖"宽度、视口高度、内容高度"三个布局条件
   * 同时就绪。任一条件始终不满足（例如章节极短、内容高度一直为 0），
   * 恢复就永远不会落地。而恢复期间我们会**挡住滚动进度上报**
   * （否则恢复前的 `y = 0` 事件会把进度冲成 0，见 `onReaderScroll`）——
   * 没有时限的话，那道上报闸门就永久关闭，用户滚动时进度永不更新。
   *
   * 取 1500ms：远大于正常布局耗时（几十毫秒），又短到用户察觉不到
   * "进度怎么不更新"。超过它说明布局确实出了问题，此时**保住进度上报**
   * 比保住位置恢复更重要。
   */
  static readonly SCROLL_RESTORE_GIVEUP_MS: number = 1500;
  /**
   * 滚动模式"滚停后晋升可见章"的防抖（ms）。
   *
   * ⚠️ 晋升 = 完整加载一章（解码 + 划线查询 + 窗口平移 + 布局重建），
   * 几十毫秒级的重活。用户一屏滑过去可能连跨两章边界，
   * 每次进入新章都立即晋升会把主线程打满、滚动卡顿。
   * 滚停 250ms 后仍停在相邻章才真的换章 —— 观感无损失
   * （预览文字已在视口里），性能却稳了。
   */
  static readonly SCROLL_PROMOTE_DEBOUNCE_MS: number = 250;
  /**
   * 导入确认页"换编码重新解析"前让出主线程的延迟（ms）。
   *
   * ⚠️ 存在的理由：`ImportService.parseInto` 是**同步**的 CPU 密集操作
   * （整文件解码 + 行级正则），10 MB 级文件要数秒。若在点击回调里直接调用，
   * 主线程会被按住 —— 连"正在重新解析…"这行提示都画不出来，
   * 用户看到的是**点了没反应，随后可能被系统判定无响应**（实测反馈"卡死闪退"）。
   *
   * 取 0ms（`setTimeout` 的最小延迟）就够：它把解析推到**下一轮事件循环**，
   * 让当前这一帧先把 `parsing = true` 渲染出来。
   * 不要写成 16/50 这种"看起来更稳"的值 —— 用户会感到一次无谓的延迟，
   * 而真正的解法是 taskpool（见设计文档风险表），不是把延迟调大。
   */
  static readonly IMPORT_REPARSE_DEFER_MS: number = 0;

  // ---------------------------------------------------------------- 分章
  /** 首章之前超过这么多字节才补一条"前言" */
  static readonly PREFACE_MIN_BYTES: number = 200;
  /** 至少命中多少条章节标记才认为规则可靠 */
  static readonly MIN_CHAPTER_MARKERS: number = 3;
  /** 章节标题行的最大长度（超过必然不是标题） */
  static readonly MAX_TITLE_LINE_LENGTH: number = 60;
  /** 兜底切分时每章约多少个字符 */
  static readonly FALLBACK_CHARS_PER_CHAPTER: number = 8000;
  /**
   * 分章结果"可疑"的判据：平均每章超过这么多字。
   *
   * ⚠️ 为什么需要它：正常小说的章节在几千字量级（网文 2000~5000 字/章），
   * 平均十万字一章几乎只可能是**编码选错导致分章失败**。
   * 这种书的单章会触发数千次分页测量，让阅读页白屏假死
   * （见 `PaginationService.MAX_MEASURED_CHARS`），必须在入库前提示用户换编码。
   *
   * 取 10 万：远高于任何正常章节，又低于"分章失败"产生的量级（几十万字），
   * 不会把"超大单章但结构正常的书"误判掉太多。
   */
  static readonly SUSPICIOUS_AVG_CHAPTER_CHARS: number = 100000;

  // ---------------------------------------------------------------- 默认排版
  static readonly DEFAULT_FONT_SIZE: number = 18;
  /**
   * 默认行距。
   *
   * ⚠️ 1.6 → 2.0（本次重构）：中文正文在手机窄栏（约 18 字/行）里，
   * 1.6 的行间呼吸不足，连续读几页容易串行；2.0 一屏少一行
   * 但连续性明显更好。上限 `MAX_LINE_HEIGHT`(2.4) 仍留有再调大的空间。
   */
  static readonly DEFAULT_LINE_HEIGHT: number = 2.0;
  static readonly DEFAULT_PARAGRAPH_SPACING: number = 0.5;
  static readonly DEFAULT_PAGE_MARGIN: number = 16;
  /**
   * 段首缩进（字）。
   *
   * ⚠️ **它已经不是可调设置**（用户要求移除）：中文正文的段首缩进
   * 几乎总是两个字，做成滑块只是多一个永远不会被动的控件。
   * 现在把它**写死成默认值**，但**保留机制** —— `firstLineIndent`
   * 仍然参与三处：分页的每行字数（首行少放两个字）、渲染时补缩进字符、
   * 以及 `layoutKey` 指纹。删掉字段本身会让这三处全部失去依据。
   *
   * 判据：**移除的是"可调性"，不是"能力"**。将来若要重新开放，
   * 把 `ReaderSettings` 里那个字段接回界面即可。
   */
  static readonly DEFAULT_FIRST_LINE_INDENT: number = 2;

  // ---------------------------------------------------------------- 字号范围
  /**
   * 正文字号的可调范围（vp）与步长。
   *
   * ⚠️ 从"8 个离散档位"改成滑块后，必须给出连续范围：
   *  - 下限 14：再小读不动（也是原档位的最小值）；
   *  - 上限 30：再大一屏放不下几个字（原档位的最大值）；
   *  - 步长 **1**：字号每变 1vp 都会触发一次重排 + 重新分页，
   *    步长太小（如 0.5）会让拖动过程中疯狂重算。
   *    但真正防抖动的是"松手才提交"（见 `SettingsPanel`），
   *    步长只决定可选的粒度。
   */
  static readonly MIN_FONT_SIZE: number = 14;
  static readonly MAX_FONT_SIZE: number = 30;
  static readonly FONT_SIZE_STEP: number = 1;

  // ---------------------------------------------------------------- 排版可调范围
  /**
   * 行距倍数上下限。
   *
   * ⚠️ 下限取 1.0 不是随口定的：行距小于 1 时汉字上下笔画会咬在一起，
   * 而且 `PaginationService` 用 `fontSize * lineHeight` 当行高，
   * 小于 1 会让"每页行数"虚高，分页结果与肉眼看到的对不上。
   */
  static readonly MIN_LINE_HEIGHT: number = 1.0;
  static readonly MAX_LINE_HEIGHT: number = 2.4;
  /** 段间距上限（单位：行） */
  static readonly MAX_PARAGRAPH_SPACING: number = 2.0;
  /**
   * 字间距范围（vp）。
   *
   * 上限取 6：再大就不成句子了。注意它**直接参与**每行字数计算
   * （`PaginationService.charWidth = fontSize × 0.92 + letterSpacing`），
   * 调大后每行放的字明显变少，分页会跟着重算 —— 这是预期行为。
   */
  static readonly MIN_LETTER_SPACING: number = 0;
  static readonly MAX_LETTER_SPACING: number = 6;
  /**
   * 左右页边距范围（vp）。
   *
   * 上限 48 是"内容区不至于窄到一行只放几个字"的经验值；
   * 它同时影响分页的可用宽度，渲染端也用同一个值做 padding。
   */
  static readonly MIN_PAGE_MARGIN: number = 0;
  static readonly MAX_PAGE_MARGIN: number = 48;
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
  static readonly BACKUP: string = 'BackupService';
}
