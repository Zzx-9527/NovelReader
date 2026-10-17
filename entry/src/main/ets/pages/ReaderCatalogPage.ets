import { Chapter } from '../model/Chapter';
import { Annotation } from '../model/Annotation';
import { RouteParam } from '../model/RouteParam';
import { ChapterRepository } from '../data/repository/ChapterRepository';
import { AnnotationRepository } from '../data/repository/AnnotationRepository';
import { BookSearchService, BookSearchHit, BookSearchResult } from '../data/service/BookSearchService';
import { SettingsService } from '../data/service/SettingsService';
import { AppConstants, LogTag } from '../common/constants/AppConstants';
import { AppColor, AppTheme, ReaderTheme } from '../common/theme/AppTheme';
import { Logger } from '../common/utils/Logger';
import { ReaderJumpRegistry } from '../viewmodels/ReaderJumpRegistry';
import { EmptyView } from '../views/common/EmptyView';

/** Tab 下标（用常量而不是裸数字：三个 Tab 的分支散在 build 与点击回调里） */
const TAB_CATALOG: number = 0;
const TAB_BOOKMARK: number = 1;
const TAB_SEARCH: number = 2;

/**
 * 「标注」Tab 的类型筛选项。
 *
 * ⚠️ `value` 直接用 `AppConstants` 的标注类型常量，**不另造一套枚举**：
 * 筛选值最终要与 `Annotation.type` 比对，再造一套就得写一层映射 ——
 * 而映射表是最容易"加了一种标注却忘了加一项"的地方（设计文档第 28 条）。
 *
 * ⚠️ 「全部」用 `ANNOTATION_ALL`(0) 而不是 -1：仓储的
 * `listByBook(bookId, type)` 就是用它作"不限类型"的哨兵，
 * 两处用同一个值，语义天然一致。
 */
class AnnotationFilter {
  label: string = '';
  value: number = AppConstants.ANNOTATION_ALL;

  constructor(label: string, value: number) {
    this.label = label;
    this.value = value;
  }
}

/**
 * 筛选项列表（顺序即显示顺序）。
 *
 * ⚠️ 「全部」放第一个：它是默认视图，也是"我到底标了多少东西"的入口。
 * 后三项按**使用频率**排（书签最常用），与长按菜单里的顺序保持一致 ——
 * 同一个 App 里同类选项的次序应当稳定，用户不必重新找。
 */
const ANNOTATION_FILTERS: AnnotationFilter[] = [
  new AnnotationFilter('全部', AppConstants.ANNOTATION_ALL),
  new AnnotationFilter('书签', AppConstants.ANNOTATION_BOOKMARK),
  new AnnotationFilter('划线', AppConstants.ANNOTATION_HIGHLIGHT),
  new AnnotationFilter('笔记', AppConstants.ANNOTATION_NOTE)
];

/**
 * 目录页（独立页面，**不是**弹窗）。
 *
 * 版面（自上而下）：
 * ```
 * ‹ 返回        目录 | 书签
 * ─────────────────────────
 * 第27章: 暗害
 * 第28章: 抱冰术          ← 当前章高亮
 * ...
 * ```
 *
 * ⚠️ 为什么从抽屉改成独立页面（用户实测反馈）：
 * 抽屉只占 78% 宽、且浮在正文之上，长目录（1000+ 章）翻找时既窄又容易误触正文。
 * 独立页面能整屏滚动、还能容纳"书签"这第二个 Tab。
 *
 * ⚠️ 配色走 `ReaderTheme` 而不是 `AppColor`：
 * 本页是阅读流程的一部分，用户在羊皮纸/夜间主题下打开目录，
 * 它必须跟正文同色 —— 用系统令牌会在夜间主题下变成一块白板。
 *
 * ⚠️ 选章后如何把结果告诉阅读页：见 `ReaderJumpRegistry` 的说明
 * （不用路由回传参数，因为页面栈下标脆弱、且 `back` 不承诺传参）。
 */
@Entry
@Component
struct ReaderCatalogPage {
  /** 安全区高度（vp），沉浸式全屏的配套让位，见 `EntryAbility.publishSafeArea` */
  @StorageProp('safeAreaTop') safeAreaTop: number = 0;
  @StorageProp('safeAreaBottom') safeAreaBottom: number = 0;
  /**
   * **应用级**夜间态，用于让本页跟随全局夜间。
   *
   * ⚠️ 本页是阅读流程的一部分，全局夜间打开时必须一起变深色 ——
   * 否则从黑色正文点进目录会闪出一块白板（用户要求全局一致）。
   */
  @StorageProp('appDarkMode') appDarkMode: boolean = false;

  @State chapters: Chapter[] = [];
  /**
   * **全部**标注（未筛选）。
   *
   * ⚠️ 存全量、另用 `visibleAnnotations()` 现算筛选结果，而不是"筛选时重查数据库"：
   *  - 标注量级是几十到几百条，一次全量加载后筛选是纯内存操作，切换瞬时；
   *  - 各筛选类型的**数量**需要全量才能算出来（见 `countOf`）；
   *  - 若每次切换都查库，数量就得额外查四次 `COUNT(*)`。
   * 判据：**数据量小且要反复按不同维度看同一批数据时，一次取全、内存筛选**。
   */
  @State annotations: Annotation[] = [];
  /**
   * 当前标注类型筛选值。
   *
   * ⚠️ 用 `AppConstants.ANNOTATION_ALL`(0) 作默认（"全部"），与仓储的哨兵一致。
   */
  @State annotationFilter: number = AppConstants.ANNOTATION_ALL;
  @State currentIndex: number = -1;
  @State activeTab: number = TAB_CATALOG;
  @State loading: boolean = true;
  @State error: string = '';

  // ---- 内容搜索（TAB_SEARCH）----
  /** 搜索框输入内容（受控） */
  @State searchKeyword: string = '';
  /** 搜索结果；空数组 + searched=true 表示"搜了但没命中" */
  @State searchHits: BookSearchHit[] = [];
  /** 是否执行过至少一次搜索（区分"还没搜"与"搜了没结果"两种空态） */
  @State searched: boolean = false;
  /** 搜索进行中（防连点 + 显示等待态） */
  @State searching: boolean = false;
  /** 结果被上限截断（列表尾部提示） */
  @State searchTruncated: boolean = false;

  private bookId: number = 0;
  /**
   * 用户在"设置 → 背景"里选的**阅读页配色**（light/sepia/eye_care/dark）。
   *
   * ⚠️ 这里存的是"用户的选择"，不是"最终生效的配色"——
   * 最终配色由 `theme()` 现算（全局夜间会覆盖它）。
   * 若把 `ReaderTheme` 实例直接缓存成字段，全局夜间切换后
   * 本页会继续用旧配色（字段只在 `aboutToAppear` 赋值一次）。
   */
  private readerThemeName: string = 'light';
  /** 目录列表的滚动控制器：打开时自动定位到当前章 */
  private listScroller: Scroller = new Scroller();
  /** 只自动定位一次，避免用户滚动后被反复拉回 */
  private scrolledToCurrent: boolean = false;

  /**
   * 本页最终生效的配色：用户选的阅读页配色 + **全局夜间覆盖**。
   *
   * ⚠️ 现算而不是缓存成字段：全局夜间是 `AppStorage` 里的响应式值，
   * 缓存了就不会跟着变（本页在栈里时用户仍可能切夜间）。
   * 覆盖规则本身收在 `ReaderTheme.of` 一处，这里只负责递参数。
   */
  private theme(): ReaderTheme {
    return ReaderTheme.of(this.readerThemeName, this.appDarkMode);
  }

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as RouteParam | null;
    if (params !== null && params !== undefined) {
      this.bookId = params.bookId;
      this.currentIndex = params.chapterIndex;
    }
    /**
     * 只记下"用户选的阅读页配色"；最终配色由 `theme()` 现算 ——
     * 它会把全局夜间态一并考虑进去。
     */
    this.readerThemeName = SettingsService.getInstance().loadReaderSettings().theme;

    if (this.bookId <= 0) {
      this.error = '缺少书籍参数，无法打开目录';
      this.loading = false;
      return;
    }
    // 内部已 try/catch，这里显式接住 Promise 只为避免"未处理的 Promise 拒绝"告警
    this.loadAll().catch(() => {
    });
  }

  /** 一次性加载章节与书签；两者互不影响，任一失败都不该让整页空白 */
  private async loadAll(): Promise<void> {
    try {
      this.chapters = await ChapterRepository.listByBook(this.bookId);
    } catch (e) {
      this.error = '目录加载失败';
      Logger.error(LogTag.READ, `目录加载失败: ${Logger.errText(e as Object)}`);
    }
    await this.reloadAnnotations();
    this.loading = false;
  }

  /**
   * 只重载标注。
   *
   * 与章节分开是因为**删除一条标注后只需要刷新这一半**，
   * 没必要把 1000+ 章的列表再查一遍。
   *
   * ⚠️ 查**全部类型**（`ANNOTATION_ALL`）而不是只要书签：
   * 本 Tab 已从"书签"扩展为"标注"，划线/笔记也必须能看到 ——
   * 只查书签的话，用户划了线、写了笔记，在这一页什么都找不到，
   * 会以为数据没保存（本项目踩过同类"功能做了但没入口"的问题）。
   */
  private async reloadAnnotations(): Promise<void> {
    try {
      this.annotations = await AnnotationRepository.listByBook(
        this.bookId, AppConstants.ANNOTATION_ALL);
    } catch (e) {
      Logger.error(LogTag.READ, `标注加载失败: ${Logger.errText(e as Object)}`);
    }
  }

  /**
   * 当前筛选下要显示的标注。
   *
   * ⚠️ 用**方法现算**而不是维护一份 `@State filtered` 副本：
   * 副本需要在"筛选变化"和"数据重载"两处都同步更新，漏一处就会出现
   * "删了标注但列表没变"这类不一致。现算的代价只是一次数组遍历（几百条，可忽略）。
   */
  private visibleAnnotations(): Annotation[] {
    const filter: number = this.annotationFilter;
    if (filter === AppConstants.ANNOTATION_ALL) {
      return this.annotations;
    }
    const out: Annotation[] = [];
    for (const item of this.annotations) {
      if (item.type === filter) {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 某个筛选类型下的标注数量（显示在筛选按钮上）。
   *
   * ⚠️ "全部"要返回**总数**，其余按 `type` 统计 —— 判据就是
   * `value === ANNOTATION_ALL` 这一个分支，不要另写一套"全部 = 三者相加"：
   * 那样一旦新增标注类型（比如"想法"），求和式就会漏掉它而总数仍显示旧值。
   */
  private countOf(filterValue: number): number {
    if (filterValue === AppConstants.ANNOTATION_ALL) {
      return this.annotations.length;
    }
    let count: number = 0;
    for (const item of this.annotations) {
      if (item.type === filterValue) {
        count++;
      }
    }
    return count;
  }

  /** 切换类型筛选 */
  private selectAnnotationFilter(filterValue: number): void {
    if (this.annotationFilter === filterValue) {
      return;
    }
    this.annotationFilter = filterValue;
  }

  /**
   * 标注类型的展示名。
   *
   * ⚠️ 三种类型混在同一个列表里，**必须逐条标出类型** ——
   * 否则用户看到一行文字无法判断"这是我加的书签还是写的笔记"。
   */
  private typeLabelOf(item: Annotation): string {
    if (item.isBookmark()) {
      return '书签';
    }
    if (item.isHighlight()) {
      return '划线';
    }
    return '笔记';
  }

  /**
   * 列表第二行的说明文字。
   *
   * 优先级：备注内容 > 选中的原文 > 位置。
   * 理由是"哪个信息最能帮用户认出这一条"：
   *  - 有备注 → 备注是用户自己写的，最好认；
   *  - 只有选文 → 摘一段原文；
   *  - 都没有（书签）→ 退回字符位置，与旧版行为一致。
   */
  private summaryOf(item: Annotation): string {
    if (item.hasNoteContent()) {
      return item.noteContent;
    }
    if (item.selectedText.length > 0) {
      return item.selectedText;
    }
    return item.startOffset === null ? '章首' : `第 ${item.startOffset} 字处`;
  }

  /** 章标题（与阅读页底栏同口径：标题为空时退回"第 N 章"） */
  private titleOf(chapterIndex: number): string {
    if (chapterIndex < 0 || chapterIndex >= this.chapters.length) {
      return `第 ${chapterIndex + 1} 章`;
    }
    const chapter: Chapter = this.chapters[chapterIndex];
    return chapter.title.length > 0 ? chapter.title : `第 ${chapter.displayNumber()} 章`;
  }

  /**
   * 跳章：登记待办 → 返回阅读页。
   *
   * ⚠️ 登记必须发生在 `back()` **之前**：返回是同步生效的，
   * 阅读页的 `onPageShow` 会立刻来取。
   */
  private jumpTo(chapterIndex: number, offset: number): void {
    ReaderJumpRegistry.request(chapterIndex, offset);
    this.getUIContext().getRouter().back();
  }

  /**
   * 执行全书内容搜索。
   *
   * ⚠️ 章节列表**直接传内存里的 `this.chapters`**：
   * 打开本页时已查过一次（`loadAll`），搜索再查一遍纯属浪费；
   * `BookSearchService` 只遍历不持有它，无生命周期风险。
   *
   * ⚠️ 搜索是同步重活（逐章解码全书）但包在 async 里 ——
   * 期间 UI 需要能先渲染出"正在搜索"状态，所以先置 `searching=true`、
   * `await` 一帧让 UI 提交后再开扫（与 ProfilePage 统计存储的做法同一思路）。
   */
  private async runSearch(): Promise<void> {
    const keyword: string = this.searchKeyword.trim();
    if (keyword.length === 0 || this.searching) {
      return;
    }
    this.searching = true;
    this.searched = true;
    // 先让"正在搜索…"上屏
    await new Promise<void>((resolve: (v: void) => void) => {
      setTimeout(() => resolve(), 0);
    });
    try {
      const result: BookSearchResult = await BookSearchService.search(
        this.bookId, keyword, this.chapters);
      this.searchHits = result.hits;
      this.searchTruncated = result.truncated;
    } catch (e) {
      this.searchHits = [];
      this.searchTruncated = false;
      Logger.error(LogTag.READ, `全书搜索失败: ${Logger.errText(e as Object)}`);
      this.getUIContext().getPromptAction().showToast({ message: '搜索失败' });
    } finally {
      this.searching = false;
    }
  }

  /** 点击一条搜索结果：跳到该章该偏移（语义与标注跳转一致） */
  private jumpToHit(hit: BookSearchHit): void {
    this.jumpTo(hit.chapterIndex, hit.offset);
  }

  /** 删除一条标注（书签/划线/笔记共用） */
  private removeAnnotation(annotationId: number): void {
    AnnotationRepository.softDelete(annotationId).then(() => {
      /**
       * ⚠️ 只重载数据、**不动 `annotationFilter`**：用户删掉一条后
       * 当前筛选应当保持 —— 否则"在划线列表里删一条，视图跳回全部"
       * 会让他重新找一遍位置。
       *
       * 边界（已由渲染分支覆盖）：若删掉的正好是该类型最后一条，
       * `visibleAnnotations()` 变空，页面显示"这一类还没有 + 查看全部"，
       * 而不是误报"还没有标注"。
       */
      return this.reloadAnnotations();
    }).catch((e: Object) => {
      Logger.error(LogTag.READ, `删除标注失败: ${Logger.errText(e)}`);
    });
  }

  build() {
    Column() {
      this.buildHeader()
      /**
       * 分隔线用 `theme.secondary`：本页配色跟随阅读主题，
       * 用 `AppColor.divider` 会在羊皮纸/夜间主题下露出不搭的系统灰。
       *
       * ⚠️ 并从 `Divider().color(secondary)`（**满强度**）改成
       * `AppTheme.READER_RULE_ALPHA`(0.30) 的发丝线：本页属于阅读流程，
       * 顶栏 / 常驻底栏 / 菜单栏三条线现在都是 0.30，
       * 这一条若仍是满强度，从阅读页点进目录时会看到"线突然变重"。
       *
       * 判据：**同一条语义的线，全流程必须同源** —— 深浅靠同一个常量，
       * 而不是靠各处"看起来差不多"。
       */
      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(this.theme().secondary)
        .opacity(AppTheme.READER_RULE_ALPHA)

      if (this.loading) {
        // 目录可能上千章，加载期间给个明确的等待态，而不是一片空白
        Column() {
          Text('正在加载…')
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(this.theme().secondary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column() {
          Text(this.error)
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(this.theme().secondary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.activeTab === TAB_CATALOG) {
        this.buildChapterList()
      } else if (this.activeTab === TAB_BOOKMARK) {
        this.buildAnnotationList()
      } else {
        this.buildSearchPanel()
      }
    }
    .width('100%')
    .height('100%')
    /**
     * 沉浸式让位：顶部给状态栏（否则返回按钮被盖住、点不灵），
     * 底部给手势条。背景色铺满全屏，所以让出的那两条仍是本页底色。
     */
    .padding({ top: this.safeAreaTop, bottom: this.safeAreaBottom })
    .backgroundColor(this.theme().bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 头部：左返回 + 中间两个 Tab。
   *
   * ⚠️ 用 `Stack` 而不是 `Row`：要让 Tab 组**相对整屏居中**。
   * 若用 `Row`，返回按钮会占掉左侧宽度，Tab 组就被挤偏；
   * 想在 `Row` 里补正就得写一个"与返回按钮等宽"的魔法数字，
   * 而那个宽度会随字号、字体而变 —— 迟早对不上。`Stack` 没有这个问题。
   *
   * ⚠️ 两个 Tab 标签**内联写死**，不抽带参 `@Builder`：
   * 设计文档第 15 条 —— 同一个 `build()` 里把带参 `@Builder` 调多次，参数会串位。
   * （现在是三个：目录 / 标注 / 搜索，同理。）
   */
  @Builder
  buildHeader() {
    Stack({ alignContent: Alignment.Start }) {
      // 铺满整宽的居中 Tab 组（在 Stack 下层）
      Row({ space: AppTheme.GAP_L }) {
        Text('目录')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(this.activeTab === TAB_CATALOG ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.activeTab === TAB_CATALOG ? this.theme().text : this.theme().secondary)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            this.activeTab = TAB_CATALOG;
          })

        /**
         * ⚠️ 文案从"书签"改成"标注"：本 Tab 现在同时列书签/划线/笔记
         * （见 `reloadAnnotations`）。仍叫"书签"会让用户以为划线和笔记
         * 不在这个列表里，从而根本不去点它。
         */
        Text(this.annotations.length > 0 ? `标注 ${this.annotations.length}` : '标注')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(this.activeTab === TAB_BOOKMARK ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.activeTab === TAB_BOOKMARK ? this.theme().text : this.theme().secondary)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            this.activeTab = TAB_BOOKMARK;
          })

        Text('搜索')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(this.activeTab === TAB_SEARCH ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.activeTab === TAB_SEARCH ? this.theme().text : this.theme().secondary)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            this.activeTab = TAB_SEARCH;
          })
      }
      .width('100%')
      .height(48)
      .justifyContent(FlexAlign.Center)

      // 返回按钮贴在左侧（在 Stack 上层，点击优先级更高）
      Text('‹ 返回')
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(this.theme().text)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onClick(() => {
          // 未选章就返回：不登记待办，阅读页停在原位
          this.getUIContext().getRouter().back();
        })
    }
    .width('100%')
  }

  @Builder
  buildChapterList() {
    List({ scroller: this.listScroller }) {
      ForEach(this.chapters, (chapter: Chapter) => {
        ListItem() {
          Row() {
            Text(chapter.title.length > 0 ? chapter.title : `第 ${chapter.displayNumber()} 章`)
              .fontSize(AppTheme.FONT_BODY)
              // 当前章高亮：**小面积点缀**（一行文字），保留主题色
              .fontColor(chapter.chapterIndex === this.currentIndex
                ? AppColor.accent
                : this.theme().text)
              .fontWeight(chapter.chapterIndex === this.currentIndex
                ? FontWeight.Medium
                : FontWeight.Normal)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: 14, bottom: 14 })
          .onClick(() => {
            this.jumpTo(chapter.chapterIndex, -1);
          })
        }
      }, (chapter: Chapter) => `${chapter.chapterIndex}_${chapter.title}`)
    }
    .layoutWeight(1)
    .width('100%')
    // 上千章的长列表：只多缓存几屏，别把整本都建出来
    .cachedCount(6)
    .scrollBar(BarState.Off)
    .onAppear(() => {
      // 打开目录时自动滚到当前章 —— 1000+ 章的书里，不定位等于每次都要手翻
      if (!this.scrolledToCurrent && this.currentIndex >= 0
        && this.currentIndex < this.chapters.length) {
        this.scrolledToCurrent = true;
        this.listScroller.scrollToIndex(this.currentIndex, false);
      }
    })
  }

  /**
   * 标注类型筛选栏：全部 / 书签 / 划线 / 笔记。
   *
   * ⚠️ 每项都带**数量**：用户点"划线"前就想知道值不值得点 ——
   * 显示 0 的项还能顺手回答"我到底划过没有"。这是零成本的（数据已在内存里）。
   *
   * ⚠️ 选中态用**中性填充**（`theme.text` 底 + `theme.bg` 字），不用点缀色：
   * 与书架的分组标签同一套规矩 —— 一行里同时有多个标签，选中的那个若用主题色，
   * 整条栏的视觉重量会全压到它身上（设计文档：大色块一律中性）。
   *
   * ⚠️ 用 `Scroll` + `Row` 而不是 `Flex(wrap)`：四项在窄屏上也放得下，
   * 且**横排一行**比换行更像"切换器"；万一以后加类型，横向滚动也比换行更可控。
   */
  @Builder
  buildFilterBar() {
    Scroll() {
      Row({ space: AppTheme.GAP_S }) {
        ForEach(ANNOTATION_FILTERS, (filter: AnnotationFilter) => {
          Text(`${filter.label} ${this.countOf(filter.value)}`)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(this.annotationFilter === filter.value
              ? this.theme().bg
              : this.theme().secondary)
            .backgroundColor(this.annotationFilter === filter.value
              ? this.theme().text
              : this.theme().barBg)
            .borderRadius(AppTheme.CHIP_RADIUS)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick(() => {
              this.selectAnnotationFilter(filter.value);
            })
        }, (filter: AnnotationFilter) => `${filter.value}`)
      }
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_S, bottom: AppTheme.GAP_S })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  @Builder
  buildAnnotationList() {
    /**
     * ⚠️ 外面套一层 `Column` 并给它 `layoutWeight(1)`：
     * `EmptyView` 自己带 `height('100%')`，直接放在本页的 Column 里
     * 会按"整页高度"算、把头部顶出去。套一层有界容器就正常了。
     */
    Column() {
      /**
       * 类型筛选栏。
       *
       * ⚠️ **只在有标注时显示**：一条都没有时它整行都是 0，纯属占地方；
       * 而且空状态里已经说明了"怎么加标注"，筛选栏反而会让人以为"是不是被筛掉了"。
       */
      if (this.annotations.length > 0) {
        this.buildFilterBar()
      }

      if (this.annotations.length === 0) {
        /**
         * ⚠️ 空状态必须包在**带 `layoutWeight(1)` 的 `Column`** 里。
         *
         * `EmptyView` 自身是 `height('100%')` —— 它取的是**父容器**高度。
         * 现在父容器里多了筛选栏这个兄弟节点，直接放进去它仍按"整栏高度"算，
         * 会把筛选栏顶出可视区（本项目已在目录页记过同类坑：
         * "EmptyView 直接放在本页 Column 里会把头部顶出去"）。
         * 套一层有界容器，它拿到的就是"扣掉筛选栏之后的余量"。
         */
        Column() {
          // 复用通用空状态组件，文案指明**怎么加**，而不是只说"没有"
          EmptyView({
            title: '还没有标注',
            hint: '阅读时长按选中正文，在弹出菜单里选「书签 / 划线 / 笔记」'
          })
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.visibleAnnotations().length === 0) {
        /**
         * ⚠️ 区分"一条标注都没有"与"这一类没有"两种情况。
         *
         * 后者若复用上面的空状态，会显示"还没有标注"—— 而用户明明有几十条，
         * 只是当前筛的是"划线"。那会让人以为数据丢了。
         * 这里明确指向筛选条件，并给出退路（切回全部）。
         */
        Column() {
          EmptyView({
            title: '这一类还没有',
            hint: '换一个筛选看看，或点「全部」',
            actionText: '查看全部',
            onAction: () => {
              this.selectAnnotationFilter(AppConstants.ANNOTATION_ALL);
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        List() {
          ForEach(this.visibleAnnotations(), (item: Annotation) => {
            ListItem() {
              Row() {
                Column({ space: 4 }) {
                  /**
                   * 第一行：**类型标签 + 章节名**。
                   *
                   * ⚠️ 类型必须显示：三种标注混在一个列表里，
                   * 不标类型用户没法判断"这条是我加的书签还是写的笔记"。
                   * 类型用小面积点缀色（与"当前章高亮"同一套用法）。
                   */
                  Row({ space: AppTheme.GAP_S }) {
                    Text(this.typeLabelOf(item))
                      .fontSize(10)
                      .fontColor(AppColor.accent)
                      .borderRadius(4)
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                      .backgroundColor(this.theme().barBg)

                    Text(this.titleOf(item.chapterIndex))
                      .fontSize(AppTheme.FONT_BODY)
                      .fontColor(this.theme().text)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .width('100%')

                  /**
                   * 第二行：备注 > 选文 > 位置（见 `summaryOf`）。
                   *
                   * ⚠️ 最多两行并截断：备注可能很长，不截断会把列表撑得很难扫。
                   */
                  Text(this.summaryOf(item))
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(this.theme().secondary)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text('删除')
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppColor.danger)
                  .padding({ left: 12, top: 8, bottom: 8 })
                  .onClick(() => {
                    this.removeAnnotation(item.id);
                  })
              }
              .width('100%')
              .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: 12, bottom: 12 })
              .onClick(() => {
                /**
                 * 标注可能只记了章首（`startOffset` 为 null），此时落到章首即可。
                 *
                 * ⚠️ 先赋给局部变量再判断：`startOffset` 的类型是 `number | null`，
                 * 直接在**属性访问**上做三元判断，ArkTS 的类型收窄不一定生效
                 * （它只保证局部变量的收窄）。落到局部变量上就确定了。
                 */
                const start: number | null = item.startOffset;
                const offset: number = start === null ? -1 : start;
                this.jumpTo(item.chapterIndex, offset);
              })
            }
          }, (item: Annotation) => `${item.id}_${item.type}_${item.noteContent}_${item.selectedText}`)
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(6)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ============================================================ 内容搜索

  /**
   * 搜索面板：输入框 + 结果列表。
   *
   * ⚠️ 四种状态互斥地覆盖：未搜过（引导文案）/ 搜索中 / 搜了没命中 /
   * 有结果。与标注 Tab 一样，"搜了但为空"绝不能复用"还没搜"的引导，
   * 否则用户会以为搜索坏了。
   *
   * ⚠️ 输入框回车或点「搜索」都触发；输入为空时按钮置灰。
   */
  @Builder
  buildSearchPanel() {
    Column() {
      Row({ space: AppTheme.GAP_S }) {
        TextInput({
          text: this.searchKeyword,
          placeholder: '搜索正文内容'
        })
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(this.theme().text)
          .placeholderColor(this.theme().secondary)
          .placeholderFont({ size: AppTheme.FONT_BODY })
          .backgroundColor(this.theme().barBg)
          .borderRadius(AppTheme.CHIP_RADIUS)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchKeyword = value;
          })
          .onSubmit(() => {
            this.runSearch();
          })

        Text('搜索')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(this.searchKeyword.trim().length > 0 && !this.searching
            ? AppColor.accent : this.theme().secondary)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            this.runSearch();
          })
      }
      .width('100%')
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_S, bottom: AppTheme.GAP_S })

      if (this.searching) {
        Column() {
          Text('正在搜索…')
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(this.theme().secondary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (!this.searched) {
        Column() {
          EmptyView({
            title: '搜索全书内容',
            hint: '输入关键词，找出它在哪些章节出现过'
          })
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.searchHits.length === 0) {
        Column() {
          EmptyView({
            title: '没有找到',
            hint: `正文中没有「${this.searchKeyword.trim()}」`
          })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        List() {
          ForEach(this.searchHits, (hit: BookSearchHit) => {
            ListItem() {
              Column({ space: 4 }) {
                Row({ space: AppTheme.GAP_S }) {
                  Text(hit.chapterTitle)
                    .fontSize(AppTheme.FONT_BODY)
                    .fontColor(this.theme().text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')

                Text(hit.snippet)
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(this.theme().secondary)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding({
                left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING,
                top: 12, bottom: 12
              })
              .onClick(() => {
                this.jumpToHit(hit);
              })
            }
          }, (hit: BookSearchHit) =>
            `${hit.chapterIndex}_${hit.offset}_${hit.snippet}`)
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(6)
        .scrollBar(BarState.Off)

        if (this.searchTruncated) {
          Text('结果较多，仅显示前 200 条，可换更具体的关键词')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(this.theme().secondary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8 })
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
  }
}
