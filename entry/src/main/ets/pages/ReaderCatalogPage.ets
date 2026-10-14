import { Chapter } from '../model/Chapter';
import { Annotation } from '../model/Annotation';
import { RouteParam } from '../model/RouteParam';
import { ChapterRepository } from '../data/repository/ChapterRepository';
import { AnnotationRepository } from '../data/repository/AnnotationRepository';
import { SettingsService } from '../data/service/SettingsService';
import { AppConstants, LogTag } from '../common/constants/AppConstants';
import { AppColor, AppTheme, ReaderTheme } from '../common/theme/AppTheme';
import { Logger } from '../common/utils/Logger';
import { ReaderJumpRegistry } from '../viewmodels/ReaderJumpRegistry';
import { EmptyView } from '../views/common/EmptyView';

/** Tab 下标（用常量而不是裸数字：两个 Tab 的分支散在 build 与点击回调里） */
const TAB_CATALOG: number = 0;
const TAB_BOOKMARK: number = 1;

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
  @State bookmarks: Annotation[] = [];
  @State currentIndex: number = -1;
  @State activeTab: number = TAB_CATALOG;
  @State loading: boolean = true;
  @State error: string = '';

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
    await this.reloadBookmarks();
    this.loading = false;
  }

  /**
   * 只重载书签。
   *
   * 与章节分开是因为**删除书签后只需要刷新这一半**，
   * 没必要把 1000+ 章的列表再查一遍。
   */
  private async reloadBookmarks(): Promise<void> {
    try {
      this.bookmarks = await AnnotationRepository.listByBook(
        this.bookId, AppConstants.ANNOTATION_BOOKMARK);
    } catch (e) {
      Logger.error(LogTag.READ, `书签加载失败: ${Logger.errText(e as Object)}`);
    }
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

  private removeBookmark(annotationId: number): void {
    AnnotationRepository.softDelete(annotationId).then(() => {
      return this.reloadBookmarks();
    }).catch((e: Object) => {
      Logger.error(LogTag.READ, `删除书签失败: ${Logger.errText(e)}`);
    });
  }

  build() {
    Column() {
      this.buildHeader()
      // 分隔线用 `theme.secondary`：本页配色跟随阅读主题，
      // 用 `AppColor.divider` 会在羊皮纸/夜间主题下露出不搭的系统灰
      Divider().color(this.theme().secondary)

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
      } else {
        this.buildBookmarkList()
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

        Text(this.bookmarks.length > 0 ? `书签 ${this.bookmarks.length}` : '书签')
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontWeight(this.activeTab === TAB_BOOKMARK ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.activeTab === TAB_BOOKMARK ? this.theme().text : this.theme().secondary)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            this.activeTab = TAB_BOOKMARK;
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

  @Builder
  buildBookmarkList() {
    /**
     * ⚠️ 外面套一层 `Column` 并给它 `layoutWeight(1)`：
     * `EmptyView` 自己带 `height('100%')`，直接放在本页的 Column 里
     * 会按"整页高度"算、把头部顶出去。套一层有界容器就正常了。
     */
    Column() {
      if (this.bookmarks.length === 0) {
        // 复用通用空状态组件，文案指明**怎么加**，而不是只说"没有"
        EmptyView({
          title: '还没有书签',
          hint: '阅读时点右上角「书签」即可添加'
        })
      } else {
        List() {
          ForEach(this.bookmarks, (item: Annotation) => {
            ListItem() {
              Row() {
                Column({ space: 4 }) {
                  Text(this.titleOf(item.chapterIndex))
                    .fontSize(AppTheme.FONT_BODY)
                    .fontColor(this.theme().text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(item.startOffset === null ? '章首' : `第 ${item.startOffset} 字处`)
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(this.theme().secondary)
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text('删除')
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppColor.danger)
                  .padding({ left: 12, top: 8, bottom: 8 })
                  .onClick(() => {
                    this.removeBookmark(item.id);
                  })
              }
              .width('100%')
              .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: 12, bottom: 12 })
              .onClick(() => {
                /**
                 * 书签可能只记了章首（`startOffset` 为 null），此时落到章首即可。
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
          }, (item: Annotation) => `${item.id}`)
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
}
