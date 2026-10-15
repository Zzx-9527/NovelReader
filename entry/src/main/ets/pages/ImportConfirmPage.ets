import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { AppFont } from '../common/theme/AppFont';
import { AppConstants } from '../common/constants/AppConstants';
import { Encodings } from '../common/utils/EncodingDetector';
import { FileUtil } from '../common/utils/FileUtil';
import { Logger } from '../common/utils/Logger';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { ImportPreparation, ImportResult } from '../data/service/ImportService';
import { ThemeMenu } from '../views/common/ThemeMenu';

/**
 * 候选编码。
 *
 * ⚠️ 顺序按"中文 TXT 的实际概率"排：UTF-8 与 GB18030 覆盖绝大多数，
 * GBK 是 GB18030 的子集（老文件常见）、BIG5 面向繁体。
 * UTF-16 两种放最后 —— 很少见，但确实是误判的高发区（设计文档记过
 * "GBK 文件被误判成 UTF-16 → 正文满屏乱码"）。
 *
 * ⚠️ **必须是模块级常量，绝不能写成 struct 的 `static` 成员**。
 * ArkTS 的 `@Component struct` **不支持静态成员** ——
 * 写成 `private static readonly` 会让页面无法正常工作（本项目实测踩过）。
 * 全项目惯例都是这样：`SettingsPanel` 的 `PAGE_MODES`、
 * `Index` 的 `TAB_LABELS`、`ChapterParser` 的 `HIGH_RULES`、
 * `ReaderCatalogPage` 的 `TAB_CATALOG` —— 一律放模块顶层。
 *
 * 判据：**struct 里只放"与实例相关的东西"**（状态、方法、回调），
 * 一切常量都提到文件顶部。
 */
const ENCODING_OPTIONS: string[] = [
  Encodings.UTF8, Encodings.GB18030, Encodings.GBK,
  Encodings.BIG5, Encodings.UTF16LE, Encodings.UTF16BE
];

/**
 * 预览显示的章节条数。
 *
 * 取 8：够看出"分章是否合理、编码是否乱码"，又不会把页面撑得很长
 * （预览区本来只是给用户一个判断依据，不是目录）。
 */
const PREVIEW_COUNT: number = 8;

/**
 * 导入确认页（选完文件、尚未入库）。
 *
 * 版面（自上而下，与效果稿一致；标题栏不变）：
 * ```
 * ‹ 返回        导入确认
 * ───────────────────────────────
 * ┌ 文件  长夜将尽.txt ┐
 * │ 大小  290.0 万字   │          ← 信息卡：账目行式四行
 * │ 编码  GB18030      │
 * │ 章节  35 章        │
 * └───────────────────┘
 * ⚠ 分章结果可疑 / 置信度低     ← 朱色左边线告警块（按状态出现）
 * 书名   [________________]      ← 可编辑，初值取自文件名
 * 编码   utf-8  gb18030 …        ← 点击即重新分章预览
 * 章节预览            前 8 / 共 35
 *   01  第一章                ← 序号 + 发丝线行
 *   02  第二章
 * ───────────────────────────────
 *      [取消]   [ 导入书架 ]    ← 描边 + 朱砂实心
 * ```
 *
 * ⚠️ **为什么必须有这一页**（设计文档 §P1 / 附录 B 第 6 项）：
 * 自动编码探测不可能对每个 TXT 都准确，而编码错了正文就是满屏乱码。
 * 旧流程"选完直接入库 + 一句 toast"让用户无法核对、也无法在入库前改编码 ——
 * 只能等发现乱码后回书架长按"换编码"，而那一步会**连带删除书签/笔记**。
 * 把确认提前到写库之前，就从根上避免了这次返工。
 *
 * ⚠️ 数据来源：**共享的 `BookShelfViewModel.state.pendingImport`**，
 * 不走路由参数（含上千章节对象，序列化既慢又可能丢字段）。
 * 本页只取"展示需要的标量"存进**基本类型**的 `@State` 字段。
 *
 * ⚠️ 配色走 `AppColor` 而**不是** `ReaderTheme`：本页属于书架流程
 * （不是阅读页内部），要跟随系统深浅色，与书架页一致。
 */
@Entry
@Component
struct ImportConfirmPage {
  /** 安全区高度（vp），沉浸式全屏的配套让位 */
  @StorageProp('safeAreaTop') safeAreaTop: number = 0;
  @StorageProp('safeAreaBottom') safeAreaBottom: number = 0;

  /**
   * 与书架页**共享同一个 ViewModel 实例**（通过 `ShelfRefreshRegistry` 取）。
   *
   * ⚠️ 不能在本页 `new BookShelfViewModel()`：那样 `state.pendingImport`
   * 是空的（待确认数据在书架页那个实例里），页面会显示成"没有待导入的内容"。
   */
  private vm: BookShelfViewModel | null = null;

  /**
   * 展示字段一律用**基本类型**，不用"一个 class 装所有字段"。
   *
   * ⚠️ 为什么不用"一个 class 装所有展示字段"的聚合对象：
   *  1. `@State` 对 class 的观察只到**第一层属性**，嵌套/数组内部的变化
   *     不一定触发重绘 —— 而本页每一块都要独立更新（编码、预览、进度提示）；
   *  2. 字段少而扁平时，"哪个值驱动哪一块"一眼可见，排查成本最低。
   * 代价是字段多几行，换来的是行为可预测。
   */
  @State private title: string = '';
  @State private encoding: string = '';
  /**
   * 章节预览行，格式 `"标题\u0000字数"`（效果稿每行右侧显示字数）。
   *
   * ⚠️ 用不可见分隔符拼成字符串数组而不是对象数组：本页字段一律是
   * **基本类型**（`@State` 对 class/对象的观察只到第一层，字段扁平最可靠）。
   */
  @State private previewRows: string[] = [];
  @State private chapterCount: number = 0;
  @State private wordCount: number = 0;
  /** 文件字节大小（信息卡「大小」行；来自 `ImportPreparation.fileSize`） */
  @State private fileSize: number = 0;
  @State private lowConfidence: boolean = false;
  @State private fallback: boolean = false;
  /**
   * 分章结果可疑（编码大概率选错了）。
   *
   * ⚠️ 它是比 `fallback` **更严重**的信号：兜底切分本身正常
   * （只是没识别到章节标记），但"只切出个位数章"意味着字节/字符比离谱 ——
   * 那本书一旦入库，打开阅读页会因单章过大触发数千次分页测量而白屏假死。
   * 所以这里用 danger 色在**入库前**明确拦住用户。
   */
  @State private suspicious: boolean = false;
  /** 正在重新解析（换编码后）。用来挡住重复点击并给出可见反馈 */
  @State private parsing: boolean = false;
  /** 是否正在执行最终导入（防连点） */
  @State private committing: boolean = false;
  /** 页面级错误（与 `vm.state.error` 分开：那是书架的，会互相盖掉） */
  @State private error: string = '';
  /** 待确认数据是否有效；false 时整页显示错误态而不是空表单 */
  @State private ready: boolean = false;

  // ── 编码选择菜单（ThemeMenu）的挂载状态 ──────────────────
  @State private menuVisible: boolean = false;
  @State private menuTitle: string = '';
  @State private menuOptions: string[] = [];
  @State private menuCurrent: number = -1;
  private menuOnPick: ((index: number) => void) | null = null;

  aboutToAppear(): void {
    this.vm = ShelfRefreshRegistry.current;
    if (this.vm === null || this.vm.state.pendingImport === null) {
      /**
       * ⚠️ 没有待确认数据时**必须走错误态**，不能继续渲染空表单：
       * 那种情况下"导入"按钮点下去只会失败，用户完全不知道发生了什么。
       * 常见成因：进程被回收后直接恢复了本页（`pendingImport` 在内存里）。
       */
      this.error = '导入数据已失效，请回书架重新选择文件';
      this.ready = false;
      return;
    }
    this.loadFromPreparation();
    this.ready = true;
  }

  /**
   * 系统返回（手势/返回键）也要清理沙箱文件。
   *
   * ⚠️ 只处理页内按钮是不够的：用户完全可能用**侧滑手势**退出，
   * 那条路径不经过 `cancelImport()`，于是 `prepare()` 复制进沙箱的文件
   * 就永远留在那里（几十 MB、且不出现在书架里，用户无从发现）。
   *
   * ⚠️ 返回 `false` 而不是 `true`：我们只是"顺手清理"，**不接管**返回行为 ——
   * 返回 `true` 会阻止系统默认的返回动作，页面就退不出去了。
   */
  onBackPress(): boolean {
    if (this.vm !== null) {
      this.vm.discardPendingImport();
    }
    return false;
  }

  /**
   * 把 ViewModel 里待确认的数据摊平成展示字段。
   *
   * ⚠️ 换编码后必须**重新调用它**：`reparsePendingImport` 会覆盖
   * `preparation.chapters`，章节数与预览都变了，不刷新就还是旧结果。
   *
   * ⚠️ 整段包 try/catch：本页是 `@Entry`，`aboutToAppear` 里抛异常会直接
   * 崩掉页面（用户看到"闪退"）。数据异常时退化成错误态，比崩掉好得多。
   */
  private loadFromPreparation(): void {
    const vm: BookShelfViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    try {
      const preparation: ImportPreparation | null = vm.state.pendingImport;
      if (preparation === null) {
        return;
      }
      const result: ImportResult = preparation.result;
      this.title = vm.pendingImportDefaultTitle();
      this.encoding = preparation.encoding;
      this.previewRows = vm.pendingImportPreviewRows(PREVIEW_COUNT);
      this.chapterCount = result.chapterCount;
      this.wordCount = result.wordCount;
      this.fileSize = preparation.fileSize;
      this.lowConfidence = result.lowConfidence;
      this.fallback = result.fallback;
      this.suspicious = result.suspicious;
    } catch (e) {
      this.error = `读取导入数据失败：${Logger.errText(e as Object)}`;
    }
  }

  /**
   * 换编码：重新分章并刷新预览。
   *
   * ⚠️ 只重新解析、**不写库**：用户可能连试几个编码，每个都入库就会产生
   * 一堆垃圾书籍记录。真正的写库在 `confirmImport()`。
   *
   * ⚠️ **重活必须推迟一帧再干**（本项目实测踩过"卡死闪退"）：
   * `ImportService.parseInto` 是**同步**的 CPU 密集操作（整文件解码 + 行级正则），
   * 10 MB 级文件要数秒。直接在这里调用会把主线程按住 ——
   * 连"正在重新解析…"这行提示都画不出来（同一帧内改的状态要等这次调用结束
   * 才可能提交），用户看到的就是**点了没反应、随后被系统判定无响应**。
   *
   * 所以：先把 `parsing = true` 提交出去让提示可见，再在**下一轮事件循环**
   * 里执行解析。彻底的解法是 taskpool（设计文档风险表已列），
   * 那要求解析器可序列化，属后续优化；推迟一帧已能消掉"假死"的观感。
   */
  private changeEncoding(encoding: string): void {
    if (this.vm === null || encoding === this.encoding || this.parsing || this.committing) {
      return;
    }
    this.parsing = true;
    this.error = '';
    setTimeout(() => {
      this.runReparse(encoding);
    }, AppConstants.IMPORT_REPARSE_DEFER_MS);
  }

  /** 真正执行重新解析（由 `changeEncoding` 推迟一帧后调用） */
  private runReparse(encoding: string): void {
    const vm: BookShelfViewModel | null = this.vm;
    if (vm === null) {
      this.parsing = false;
      return;
    }
    try {
      /**
       * ⚠️ `reparsePendingImport` 内部是同步解析，只是被 async 包了一层。
       * 这里 await 它不会让出主线程给解析过程本身，但能让"先画提示"那一步成立
       * （提示已在上一帧提交）。
       */
      vm.reparsePendingImport(encoding).then((ok: boolean) => {
        if (ok) {
          this.loadFromPreparation();
        } else {
          /**
           * ⚠️ 解析失败**保留原来的编码与预览**，不回退成空白：
           * 用户试了一个不支持的编码，界面上原来的正确结果不该因此消失。
           */
          const reason: string = vm.state.error;
          this.error = reason.length > 0
            ? `${encoding} 解析失败：${reason}`
            : `${encoding} 解析不出章节，换一个试试`;
          vm.clearError();
        }
        this.parsing = false;
      }).catch((e: Object) => {
        this.error = `解析失败：${Logger.errText(e)}`;
        this.parsing = false;
      });
    } catch (e) {
      // 同步抛错（解析器内部未捕获的异常）也要兜住，否则页面直接崩
      this.error = `解析失败：${Logger.errText(e as Object)}`;
      this.parsing = false;
    }
  }

  /** 最终导入：写库 → 返回书架 */
  private confirmImport(): void {
    const vm: BookShelfViewModel | null = this.vm;
    if (vm === null || this.committing || this.parsing) {
      return;
    }
    this.committing = true;
    this.error = '';
    vm.commitPendingImport(this.title.trim()).then((bookId: number) => {
      if (bookId <= 0) {
        this.error = vm.state.error.length > 0 ? vm.state.error : '导入失败';
        vm.clearError();
        this.committing = false;
        return;
      }
      /**
       * ⚠️ 导入成功后**必须刷新书架**：书架页只在"从阅读页返回 / 切回 Tab"时
       * 自动重载，而本页是 `pushUrl` 进来的。这里显式刷一次，
       * 不依赖根页面 `onPageShow` 的触发顺序。
       *
       * ⚠️ `committing` **不复位**：成功路径马上要 `back()`，
       * 复位会让按钮在返回动画期间重新可点，用户连点就会重复导入。
       */
      vm.reloadData().then(() => {
        this.getUIContext().getRouter().back();
      }).catch(() => {
        // 刷新失败不影响导入结果本身，直接返回（书架页自己还会再刷一次）
        this.getUIContext().getRouter().back();
      });
    }).catch((e: Object) => {
      this.error = `导入失败：${Logger.errText(e)}`;
      this.committing = false;
    });
  }

  /**
   * 取消导入：清理沙箱里已复制的文件。
   *
   * ⚠️ **必须清理**：`prepare()` 已经把文件复制进沙箱（那是为了绕过 picker
   * 的临时授权）。不清理的话，用户每取消一次就留下一个几十 MB 的孤儿文件，
   * 而它不会出现在书架里，用户永远发现不了 —— 直到存储被占满。
   */
  private cancelImport(): void {
    const vm: BookShelfViewModel | null = this.vm;
    if (vm !== null) {
      vm.discardPendingImport();
    }
    this.getUIContext().getRouter().back();
  }

  build() {
    /**
     * ⚠️ 外层 `Stack`：编码选择菜单（ThemeMenu）是全屏浮层，
     * 必须能盖住整页 —— 与书架页/分组页同一套做法。
     */
    Stack() {
      Column() {
        this.buildHeader()
        Divider().color(AppColor.divider)

        if (!this.ready) {
          this.buildUnavailable()
        } else {
          Scroll() {
            Column({ space: AppTheme.GAP_L }) {
              if (this.error.length > 0) {
                // 错误提示条：常驻在内容顶部，不遮挡下面的表单
                Text(this.error)
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppColor.danger)
                  .width('100%')
              }

              /**
               * 顶部说明（效果稿有、此前漏掉的一行）：
               * 告诉用户"下面这些是自动推断的，编码错了会满屏乱码"——
               * 这一页的全部意义就是让用户**在入库前核对**，
               * 一句说明是这一页的"为什么"。
               */
              Text('下面的分章结果由文件内容自动推断。编码选错会直接变成满屏乱码，请先核对再导入。')
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppColor.textHint)
                .lineHeight(19)
                .width('100%')

              /**
               * 版面严格对齐效果稿：信息卡 → 告警（可选）→ 分章预览。
               *
               * ⚠️ 已删除「书名输入行」与「编码胶囊行」（用户要求）：
               *  - 书名不必在这里改 —— 入库后用长按「重命名」更自然，
               *    首屏让用户填一个文本框是多余的负担；
               *  - 六个编码胶囊占地大且与"编码"这一行重复表达同一件事，
               *    改成信息卡里「编码」行右端的**「更换」**文字动作，
               *    点开 ThemeMenu 选编码（与长按书换编码同一套交互）。
               */
              this.buildFileCard()
              this.buildWarningBlock()
              this.buildPreviewRow()
            }
            .width('100%')
            .padding({
              left: AppTheme.PAGE_PADDING,
              right: AppTheme.PAGE_PADDING,
              top: AppTheme.GAP_L,
              bottom: AppTheme.GAP_L
            })
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .width('100%')

          this.buildActionBar()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.bgPage)
      /**
       * 沉浸式让位：顶部给状态栏（否则返回按钮被盖住、点不灵），
       * 底部给手势条。背景色铺满全屏，所以让出的那两条仍是本页底色。
       */
      .padding({ top: this.safeAreaTop, bottom: this.safeAreaBottom })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 编码选择菜单（最上层）
      if (this.menuVisible) {
        ThemeMenu({
          title: this.menuTitle,
          options: this.menuOptions,
          dangerIndexes: '',
          currentIndex: this.menuCurrent,
          onPick: (index: number) => {
            this.menuVisible = false;
            const cb = this.menuOnPick;
            if (cb !== null) {
              cb(index);
            }
          },
          onClose: () => {
            this.menuVisible = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 待确认数据失效时的兜底页面 */
  @Builder
  buildUnavailable() {
    Column({ space: AppTheme.GAP_M }) {
      Text('✗')
        .fontSize(28)
        .fontColor(AppColor.danger)
      Text(this.error)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppColor.textPrimary)
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
      Button('返回书架')
        .fontSize(AppTheme.FONT_BODY)
        .backgroundColor(AppColor.primary)
        .fontColor(AppColor.onPrimary)
        .onClick(() => {
          // 这里不用 cancelImport：没有可清理的数据，直接返回
          this.getUIContext().getRouter().back();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  buildHeader() {
    Stack({ alignContent: Alignment.Start }) {
      // 铺满整宽的居中标题（在 Stack 下层）
      Text('导入确认')
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .height(48)
        .textAlign(TextAlign.Center)

      // 返回按钮贴在左侧（在 Stack 上层，点击优先级更高）
      Text('‹ 返回')
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppColor.textPrimary)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onClick(() => {
          // 返回 = 取消：与"取消"按钮同一语义，都要清理沙箱文件
          this.cancelImport();
        })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 文件信息卡

  /**
   * 文件信息卡：文件 / 大小 / 编码 / 章节，**账目行**式排版
   * （左标签、右值、行间发丝线），与统计页同一套语汇。
   *
   * ⚠️ 原实现把"分章结果"散在编码行下面的一行字里，用户要扫三块
   * 才能凑齐"这是什么文件、多大、什么编码、分出几章"。
   * 收成一张卡，四行对齐，一眼读完。
   *
   * ⚠️ 尺寸在真机上"整体小一圈、页面空一大截"（用户反馈），
   * 因此本轮统一放大：标签列 64 → **80**、标签字号 12 → **13**、
   * 值字号 14 → **16**、行内边距 14 → **18**、标签字距 1 → 1.5。
   * 四个值（文件名/大小/编码/章节）现在有明确的"表"的量感。
   *
   * ⚠️ 四行**内联写死**，不抽带参 `@Builder`（设计文档第 15/41 条：串位）。
   */
  @Builder
  buildFileCard() {
    Column() {
      // ① 文件名
      Row() {
        Text('文件')
          .fontSize(13)
          .fontColor(AppColor.textHint)
          .letterSpacing(1.5)
          .width(80)
        Text(this.title.length > 0 ? this.title : '未命名')
          .fontSize(16)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 18, bottom: 18, left: 18, right: 18 })

      // ② 大小（**文件字节**，不是字数 —— 效果稿里这一行是"412 KB"）
      Row() {
        Text('大小')
          .fontSize(13)
          .fontColor(AppColor.textHint)
          .letterSpacing(1.5)
          .width(80)
        Text(FileUtil.humanSize(this.fileSize))
          .fontSize(16)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 18, bottom: 18, left: 18, right: 18 })
      .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })

      /**
       * ③ 编码 + **「更换」**（效果稿的关键交互）。
       *
       * ⚠️ 「更换」放在这一行右端、与置信度小注同行：编码是"可以改的一项"，
       * 动作就该贴着它，而不是散在下面的胶囊行里。
       * 点开 `ThemeMenu` 选编码 —— 与长按书「换编码」用的是同一个菜单组件，
       * 两处交互因此一致。
       */
      Row({ space: AppTheme.GAP_S }) {
        Text('编码')
          .fontSize(13)
          .fontColor(AppColor.textHint)
          .letterSpacing(1.5)
          .width(80)

        Text(this.parsing ? '正在重新解析…' : this.encoding)
          .fontSize(16)
          .fontColor(this.parsing ? AppColor.accent : AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.lowConfidence && !this.parsing) {
          Text('置信度低')
            .fontSize(12)
            .fontColor(AppColor.textHint)
        }

        Blank()

        Text('更换')
          .fontSize(13)
          .fontColor(AppColor.accent)
          .padding({ left: 10, right: 2, top: 6, bottom: 6 })
          .onClick(() => {
            this.showEncodingMenu();
          })
      }
      .width('100%')
      .padding({ top: 18, bottom: 18, left: 18, right: 18 })
      .alignItems(VerticalAlign.Center)
      .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })

      // ④ 章节
      Row() {
        Text('章节')
          .fontSize(13)
          .fontColor(AppColor.textHint)
          .letterSpacing(1.5)
          .width(80)
        Text(this.parsing ? '—' : `${this.chapterCount} 章`)
          .fontSize(16)
          .fontColor(AppColor.textPrimary)
          .fontFeature(AppFont.TABULAR)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 18, bottom: 18, left: 18, right: 18 })
      .border({ width: { top: AppTheme.HAIRLINE }, color: AppColor.divider })
    }
    .width('100%')
    .backgroundColor(AppColor.bgCard)
    .borderRadius(AppTheme.CARD_RADIUS)
    .clip(true)
  }

  /**
   * 「更换」编码：弹主题化菜单（与长按书「换编码」同一套组件）。
   *
   * ⚠️ 当前编码标上「（当前）」并给朱点：用户一眼看出现在是哪一个。
   * ⚠️ 选完只重新分章预览、**不写库**（写库在底部「导入书架」）。
   */
  private showEncodingMenu(): void {
    if (this.parsing || this.committing) {
      return;
    }
    /**
     * ⚠️ 复用模块级的 `ENCODING_OPTIONS`，**不在这里再写一份**：
     * 编码候选列表（顺序与内容）只允许有一个来源（设计文档第 28 条）。
     */
    const labels: string[] = [];
    let currentIndex: number = -1;
    for (let i = 0; i < ENCODING_OPTIONS.length; i++) {
      const item: string = ENCODING_OPTIONS[i];
      labels.push(item === this.encoding ? `${item}（当前）` : item);
      if (item === this.encoding) {
        currentIndex = i;
      }
    }

    this.menuTitle = '选择编码';
    this.menuOptions = labels;
    this.menuCurrent = currentIndex;
    this.menuOnPick = (index: number) => {
      const picked: string = ENCODING_OPTIONS[index];
      if (picked === undefined || picked === this.encoding) {
        return;
      }
      this.changeEncoding(picked);
    };
    this.menuVisible = true;
  }

  /**
   * 告警块：低置信度 / 兜底切分 / 章节可疑，三档共用一个**朱色左边线**的提示块。
   *
   * ⚠️ 原实现是三段散落的裸文字，权重靠颜色硬撑；收成带左边线的块后
   * "这是一条需要你停下来看的提示"有了形状 —— 与效果稿一致。
   * 可疑（suspicious）最严重，独占文案；低置信度与兜底可并存，取并集文案。
   */
  @Builder
  buildWarningBlock() {
    if (this.suspicious) {
      this.warningBody(
        '只解析出很少的章节，编码可能不正确。建议更换编码后重新解析，否则阅读时可能卡住。'
      )
    } else if (this.lowConfidence || this.fallback) {
      this.warningBody(
        this.lowConfidence
          ? '请核对下方章节名是否有乱码。若显示异常，点上面的「更换」改选 GB18030 或 GBK。'
          : '没有找到标准章节标记，已按字数自动切分；阅读时若章节不对可换编码重试。'
      )
    }
  }

  /**
   * 告警块本体（效果稿样式）：**朱色左边线 + 淡朱底 + 两行文字**。
   *
   * ⚠️ 三处尺寸是刻意收小的（真机实测"占地太大"）：
   *  - 左边线 3vp → **2.5vp 且不撑满高度**（用 `alignSelf(ItemAlign.Stretch)`
   *    配上下 padding 让线随内容高度、不随容器拉伸）；
   *  - 上下 padding 各 12/13 → **10/11**；
   *  - 标题与说明之间 4 → **3**。
   * 效果稿里它就是"两行小字的一块提示"，不该占掉小半屏。
   *
   * ⚠️ 底色用 `accent` 的极低不透明度叠在纸面上（不是 `bgCard` 实心白）：
   * 实心白块与下面信息卡同色，读起来像"另一张卡"；淡朱底才读得出
   * "这是一条警示"。用 `opacity` 叠色而非新令牌，深浅模式自动成立。
   */
  @Builder
  warningBody(message: string) {
    /**
     * ⚠️ **单层 `Row`，不用 `Stack` 叠底色**（真机两轮实测的结论）。
     *
     * 前两版都用 `Stack`：底色层 + 内容层。但 `Stack` 的高度由**最高子节点**
     * 决定，而底色层在没有固定高度时仍会去要满父容器的剩余空间 ——
     * `height('100%')` 会撑满、`alignSelf(Stretch)` 也会被拉满，
     * 于是整块被拉成一大片（用户连续两轮反馈"红色区域为什么这么大"）。
     *
     * 现在：**一个 `Row` 直接承载底色**，高度由内容（两行文字）自然决定。
     * 底色用带 alpha 的 `#14A8342A`（朱砂 8%）而不是 `opacity` 叠层 ——
     * `opacity` 会波及子节点文字，alpha 色值不会。
     */
    Row({ space: 10 }) {
      // 朱色左边线：高度由 Row 的内容决定（不写 height）
      Column()
        .width(2.5)
        .alignSelf(ItemAlign.Stretch)
        .backgroundColor(AppColor.accent)

      Column({ space: 3 }) {
        Row({ space: 5 }) {
          Text('⚠')
            .fontSize(11)
            .fontColor(AppColor.accent)
          Text(this.suspicious ? '分章结果可疑' : '编码识别置信度偏低')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.accent)
        }

        Text(message)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textSecondary)
          .lineHeight(17)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 10, bottom: 11, left: 0, right: 12 })
    // 淡朱底：直接写在 Row 上（#14 = alpha 8%），不叠层、不撑高
    .backgroundColor('#14A8342A')
    .borderRadius(AppTheme.ITEM_RADIUS)
  }

  // ------------------------------------------------------------ 预览

  /**
   * 分章预览（严格照效果稿）：
   * ```
   * ┌─────────────────────────────────────┐
   * │ 分章预览              前 4 章 / 共 35 │  ← 标题**在卡片内**，下方一条发丝线
   * │ ─────────────────────────────────── │
   * │ 01   第一章 · 落雪          2 840 字 │  ← 行高 40，字号 13 / 11
   * │ 02   第二章 · 旧信          3 120 字 │
   * └─────────────────────────────────────┘
   * ```
   *
   * ⚠️ **标题行必须在卡片内部**（用户指出）：早先把它放在卡片外面，
   * 视觉上是"一个游离的标签 + 一张表"，而效果稿里它是一个**带表头的卡**。
   * 表头下方那条发丝线与行间线同色同粗，把表头与数据行分开。
   *
   * ⚠️ 尺寸照效果稿收小：内边距 16 → **14**，章节名 `FONT_BODY`(14) → **13**，
   * 字数 `FONT_CAPTION`(12) → **11**，行高 12+12 → **11+11**（总高约 40）。
   * 原来那版整体大一圈，与上面的信息卡不成比例。
   *
   * ⚠️ 每行**右侧带字数**：某一章字数异常大（如 8 万字）通常说明分章没分对
   * （编码错了），字数是最好的判据 —— 效果稿里这一列不是装饰。
   */
  @Builder
  buildPreviewRow() {
    Column() {
      // ① 表头（卡片内）：左"分章预览"，右"前 N 章 / 共 M"
      Row() {
        Text('分章预览')
          .fontSize(13)
          .fontColor(AppColor.textHint)
          .letterSpacing(1)
          .layoutWeight(1)
        Text(`前 ${this.previewRows.length} 章 / 共 ${this.chapterCount}`)
          .fontSize(12)
          .fontColor(AppColor.textHint)
          .fontFeature(AppFont.TABULAR)
      }
      .width('100%')
      .padding({ top: 15, bottom: 14, left: 16, right: 16 })

      // 表头下的发丝线（与行间线同源）
      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)

      // ② 数据行
      if (this.previewRows.length === 0) {
        Text('没有解析出章节')
          .fontSize(13)
          .fontColor(AppColor.textHint)
          .width('100%')
          .padding({ top: 16, bottom: 16, left: 16, right: 16 })
      } else {
        ForEach(this.previewRows, (row: string, index: number) => {
          Row({ space: 12 }) {
            // 序号：两位定宽（十位以上自动变三位）
            Text(`${index + 1 < 10 ? '0' : ''}${index + 1}`)
              .fontSize(12)
              .fontColor(AppColor.textHint)
              .fontFeature(AppFont.TABULAR)
              .width(24)

            // 章节名（左端，可省略）
            Text(this.previewTitle(row))
              .fontSize(15)
              .fontColor(AppColor.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            // 字数（右端，效果稿的关键一列）
            Text(`${this.previewWordCount(row)} 字`)
              .fontSize(12)
              .fontColor(AppColor.textHint)
              .fontFeature(AppFont.TABULAR)
          }
          .width('100%')
          .padding({ top: 14, bottom: 14, left: 16, right: 16 })
          .border({
            width: { top: index > 0 ? AppTheme.HAIRLINE : 0 },
            color: AppColor.divider
          })
        }, (row: string, index: number) => `${index}_${row}`)
      }
    }
    .width('100%')
    .borderRadius(AppTheme.ITEM_RADIUS)
    .backgroundColor(AppColor.bgCard)
    .clip(true)
  }

  /** 预览行里的章节标题（`"标题\u0000字数"` 的前半段） */
  private previewTitle(row: string): string {
    const parts: string[] = row.split('\u0000');
    return parts.length > 0 ? parts[0] : row;
  }

  /** 预览行里的字数（`"标题\u0000字数"` 的后半段；解析不出时返回 0） */
  private previewWordCount(row: string): number {
    const parts: string[] = row.split('\u0000');
    if (parts.length < 2) {
      return 0;
    }
    const n: number = Number.parseInt(parts[1], 10);
    return Number.isNaN(n) ? 0 : n;
  }

  // ------------------------------------------------------------ 操作栏

  @Builder
  buildActionBar() {
    Row({ space: AppTheme.GAP_M }) {
      /**
       * 取消：**描边**而非实心。
       *
       * ⚠️ 主操作（导入）现在是朱砂实心 —— 取消再铺一块 `bgCard`
       * 实心就会和它抢重量；描边表达"这是个退路，不是推荐动作"。
       */
      Button('取消')
        .fontSize(15)
        .layoutWeight(1)
        .height(48)
        .backgroundColor(AppColor.bgCard)
        .fontColor(AppColor.textSecondary)
        .border({ width: AppTheme.HAIRLINE, color: AppColor.divider })
        .borderRadius(AppTheme.ITEM_RADIUS)
        .enabled(!this.committing)
        .onClick(() => {
          this.cancelImport();
        })

      /**
       * 导入：**朱砂实心**，主操作（整页唯一的彩色大块）。
       *
       * ⚠️ `fontColor` 显式设成 `onPrimary`：深色模式下 `accent` 提亮为
       * `#C4553F`，默认白字仍可读，但显式声明才不依赖"恰好可读"。
       *
       * ⚠️ 没有章节时不给导入：入库一本"一章都没有"的书没有意义。
       */
      Button(this.committing ? '正在导入…' : '导入书架')
        .fontSize(15)
        .layoutWeight(2)
        .height(48)
        .backgroundColor(AppColor.accent)
        .fontColor(AppColor.onPrimary)
        .borderRadius(AppTheme.ITEM_RADIUS)
        // 没有章节时不给导入：入库一本"一章都没有"的书没有意义
        .enabled(!this.committing && !this.parsing && this.chapterCount > 0)
        .onClick(() => {
          this.confirmImport();
        })
    }
    .width('100%')
    .padding({
      left: AppTheme.PAGE_PADDING,
      right: AppTheme.PAGE_PADDING,
      top: AppTheme.GAP_M,
      bottom: AppTheme.GAP_M
    })
    .backgroundColor(AppColor.bgPage)
  }
}
