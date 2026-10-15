import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { AppConstants } from '../common/constants/AppConstants';
import { Encodings } from '../common/utils/EncodingDetector';
import { FileUtil } from '../common/utils/FileUtil';
import { Logger } from '../common/utils/Logger';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { ImportPreparation, ImportResult } from '../data/service/ImportService';

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
 * 全项目惯例都是这样：`SettingsPanel` 的 `FONT_SIZES` / `PAGE_MODES`、
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
 * 版面（自上而下）：
 * ```
 * ‹ 返回        导入确认
 * ───────────────────────────────
 * 书名   [________________]      ← 可编辑，初值取自文件名
 * 编码   UTF-8  GBK  GB18030 …   ← 点击即重新分章预览
 * 分章   共 1287 章 · 12.3 MB
 * 预览   第一章 …
 *        第二章 …
 * ───────────────────────────────
 *          [取消]   [导入]
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
 * 本页只取"展示需要的标量"存进**基本类型**的 `@State` 字段，
 * 避免把整个 `preparation` 交给状态系统（见下方字段说明）。
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
  @State private previewTitles: string[] = [];
  @State private chapterCount: number = 0;
  @State private wordCount: number = 0;
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
      this.previewTitles = vm.pendingImportPreview(PREVIEW_COUNT);
      this.chapterCount = result.chapterCount;
      this.wordCount = result.wordCount;
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
    Column() {
      this.buildHeader()
      Divider().color(AppColor.divider)

      if (!this.ready) {
        this.buildUnavailable()
      } else {
        if (this.error.length > 0) {
          // 错误提示条：常驻在内容顶部，不遮挡下面的表单
          Text(this.error)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.danger)
            .width('100%')
            .padding({
              left: AppTheme.PAGE_PADDING,
              right: AppTheme.PAGE_PADDING,
              top: AppTheme.GAP_S
            })
        }

        Scroll() {
          Column({ space: AppTheme.GAP_L }) {
            this.buildTitleRow()
            this.buildEncodingRow()
            this.buildSummaryRow()
            this.buildPreviewRow()
          }
          .width('100%')
          .padding({
            left: AppTheme.PAGE_PADDING,
            right: AppTheme.PAGE_PADDING,
            top: AppTheme.GAP_M,
            bottom: AppTheme.GAP_M
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

  // ------------------------------------------------------------ 书名

  @Builder
  buildTitleRow() {
    Column({ space: AppTheme.GAP_S }) {
      Text('书名')
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppColor.textPrimary)
        .width('100%')
      TextInput({ text: this.title, placeholder: '输入书名' })
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppColor.textPrimary)
        .placeholderColor(AppColor.textHint)
        .backgroundColor(AppColor.bgCard)
        .borderRadius(AppTheme.ITEM_RADIUS)
        .width('100%')
        .maxLength(60)
        .onChange((value: string) => {
          this.title = value;
        })
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 编码

  /**
   * 编码选择：**点击即重新分章预览**。
   *
   * ⚠️ 没有"确认"按钮，点了立刻重解析 —— 用户是在"试哪个编码不乱码"，
   * 加一步确认只会让他多按一次。重解析期间用 `parsing` 挡住重复点击。
   */
  @Builder
  buildEncodingRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('编码')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        if (this.parsing) {
          Text('正在重新解析…')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.accent)
        }
      }
      .width('100%')

      /**
       * ⚠️ 用 `Flex` + `wrap` 而不是 `Row`：六个编码名长短不一
       * （`GB18030` 明显更长），`Row` 里挤不下会被压缩或溢出。
       * 换行排列在小屏上也更稳。
       */
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(ENCODING_OPTIONS, (item: string) => {
          Text(item)
            .fontSize(AppTheme.FONT_CAPTION)
            // 选中态用中性填充（同书架分组标签：大色块不用点缀色）
            .fontColor(this.encoding === item
              ? AppColor.onPrimary
              : AppColor.textSecondary)
            .backgroundColor(this.encoding === item
              ? AppColor.primary
              : AppColor.bgCard)
            .borderRadius(AppTheme.CHIP_RADIUS)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ right: AppTheme.GAP_S, bottom: AppTheme.GAP_S })
            .onClick(() => {
              this.changeEncoding(item);
            })
        }, (item: string) => item)
      }
      .width('100%')

      /**
       * ⚠️ 低置信度必须**明确说清"该做什么"**，而不是只说"识别不准"：
       * 用户不知道怎么办时，正确做法是告诉他"如果下面预览是乱码就换个编码"。
       */
      if (this.lowConfidence) {
        Text('自动识别把握不大：如果预览里的章节名是乱码，请换一个编码')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.danger)
          .width('100%')
      }
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 摘要

  @Builder
  buildSummaryRow() {
    Column({ space: AppTheme.GAP_S }) {
      Row() {
        Text('分章结果')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        /**
         * ⚠️ 字数用 `humanCount`（"320.5 万字"），**不能**用 `humanSize` ——
         * 后者是**文件字节**格式化，字数喂进去会显示成"12.3 MB"这种荒谬结果。
         * 两个函数长得像，用途完全不同，别混。
         */
        Text(`共 ${this.chapterCount} 章 · ${FileUtil.humanCount(this.wordCount)}`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textSecondary)
      }
      .width('100%')

      /**
       * ⚠️ 兜底切分要提示：它意味着这本书**没有识别到标准章节标记**
       * （`第 x 章` 之类），只能按固定字数硬切。用户看到章节名是
       * "第 1 节 / 第 2 节"这种机械命名时，会以为程序出错了。
       *
       * ⚠️ "只有几章"要**升级成明确告警**：兜底切分正常也有几十章，
       * 只有个位数说明**编码八成选错了**（字节/字符比被算得离谱，
       * 按 8000 字切出来的章会大得惊人）。这种书一旦入库，
       * 打开阅读页会因为"单章几十万字"触发数千次分页测量而白屏假死。
       * 所以这里必须**在入库前**拦住，让用户换编码重试。
       */
      if (this.suspicious) {
        Text('只解析出很少的章节，编码可能不正确 —— 建议换一个编码重新解析，否则阅读时可能卡住')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.danger)
          .width('100%')
      } else if (this.fallback) {
        Text('没有找到标准章节标记，已按字数自动切分；阅读时若章节不对可换编码重试')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .width('100%')
      }
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 预览

  @Builder
  buildPreviewRow() {
    Column({ space: AppTheme.GAP_S }) {
      Text('章节预览')
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      Column({ space: 6 }) {
        if (this.previewTitles.length === 0) {
          Text('没有解析出章节')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
            .width('100%')
        } else {
          ForEach(this.previewTitles, (item: string, index: number) => {
            Text(item)
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppColor.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }, (item: string, index: number) => `${index}_${item}`)
        }
      }
      .width('100%')
      .padding(AppTheme.GAP_M)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .backgroundColor(AppColor.bgCard)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  // ------------------------------------------------------------ 操作栏

  @Builder
  buildActionBar() {
    Row({ space: AppTheme.GAP_M }) {
      /**
       * 取消：**中性填充的浅色底**而非主操作色。
       *
       * ⚠️ 它与"导入"并排，两个都用 `primary` 实心会让人分不清哪个是主操作；
       * 取消是"退出"语义，弱化处理才符合层级。
       */
      Button('取消')
        .fontSize(AppTheme.FONT_BODY)
        .layoutWeight(1)
        .height(44)
        .backgroundColor(AppColor.bgCard)
        .fontColor(AppColor.textSecondary)
        .enabled(!this.committing)
        .onClick(() => {
          this.cancelImport();
        })

      /**
       * 导入：**中性填充**（近黑/近白），主操作。
       *
       * ⚠️ `fontColor` 必须显式设成 `onPrimary`：`Button` 默认字色是白色，
       * 深色模式下 `primary` 接近白色，不设就是"白底白字"看不见。
       */
      Button(this.committing ? '正在导入…' : '导入')
        .fontSize(AppTheme.FONT_BODY)
        .layoutWeight(1)
        .height(44)
        .backgroundColor(AppColor.primary)
        .fontColor(AppColor.onPrimary)
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
    .backgroundColor(AppColor.bgCard)
  }
}
