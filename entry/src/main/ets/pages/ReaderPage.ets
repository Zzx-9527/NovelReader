import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { ReaderState, BookmarkSaveResult, BookmarkDraft, ScrollSection } from '../viewmodels/ReaderState';
import { ReaderViewModel } from '../viewmodels/ReaderViewModel';
import { ReaderJump, ReaderJumpRegistry } from '../viewmodels/ReaderJumpRegistry';
import { RouteName, RouteParam } from '../model/RouteParam';
import { AppTheme, ReaderTheme } from '../common/theme/AppTheme';
import { Logger } from '../common/utils/Logger';
import { AppConstants, LogTag } from '../common/constants/AppConstants';
import { LoadingView } from '../views/common/LoadingView';
import { ErrorView } from '../views/common/ErrorView';
import { ReaderSettings } from '../model/ReaderSettings';
import { TextRun } from '../model/TextRun';
import { ReaderWindowEffects } from '../common/utils/ReaderWindowEffects';
import {
  ReaderFooterBar, ReaderChapterHeading, ReaderSettingsSheet, ReaderBookmarkLayer, ReaderMenuLayer
} from '../views/reader/ReaderPageParts';

// 说明见 docs/阅读页实现说明.md「@Entry」
@Entry
@Component
struct ReaderPage {
  @State state: ReaderState = new ReaderState();
  private vm: ReaderViewModel = new ReaderViewModel();
  // 说明见 docs/阅读页实现说明.md「@StorageProp('safeAreaTop') safeAreaTop: number = 0;」
  @StorageProp('safeAreaTop') safeAreaTop: number = 0;
  @StorageProp('safeAreaBottom') safeAreaBottom: number = 0;
  // 说明见 docs/阅读页实现说明.md「@StorageProp('appDarkMode') appDarkMode: boolean = false;」
  @StorageProp('appDarkMode') appDarkMode: boolean = false;
  // 说明见 docs/阅读页实现说明.md「private pageAreaHeight: number = 0;」
  private pageAreaHeight: number = 0;
  private contentWidth: number = 0;
  private scrollContentHeight: number = 0;
  // 说明见 docs/阅读页实现说明.md「private scroller: Scroller = new Scroller();」
  private scroller: Scroller = new Scroller();
  private viewportHeight: number = 0;

  // ---- 平移翻页（pageMode === 'slide'）----
  private swiperController: SwiperController = new SwiperController();
  private slideAnimating: boolean = false;
  private slideTouchX: number = 0;
  // 说明见 docs/阅读页实现说明.md「@State slidePageRev: number = 0;」
  @State slidePageRev: number = 0;
  // 说明见 docs/阅读页实现说明.md「@State slidePrevText: string = '';」
  @State slidePrevText: string = '';
  @State slideNextText: string = '';
  @State slidePrevIsChapterHead: boolean = false;
  @State slideNextIsChapterHead: boolean = false;
  // 说明见 docs/阅读页实现说明.md「@State slidePrevTitle: string = '';」
  @State slidePrevTitle: string = '';
  @State slideNextTitle: string = '';
  private autoContinueBlockedUntil: number = 0;
  // 说明见 docs/阅读页实现说明.md「private sectionHeights: Map<number, number> = new Map();」
  private sectionHeights: Map<number, number> = new Map();
  // 说明见 docs/阅读页实现说明.md「private visibleChapterIndex: number = -1;」
  private visibleChapterIndex: number = -1;
  private promoteTimerId: number = -1;
  // 说明见 docs/阅读页实现说明.md「private scrollRestoreOffset: number = -1;」
  private scrollRestoreOffset: number = -1;
  // 说明见 docs/阅读页实现说明.md「private scrollRestoreRequestedAt: number = 0;」
  private scrollRestoreRequestedAt: number = 0;
  // 说明见 docs/阅读页实现说明.md「private textController: TextController = new TextController();」
  private textController: TextController = new TextController();
  // 说明见 docs/阅读页实现说明.md「private hasSelection: boolean = false;」
  private hasSelection: boolean = false;
  // 说明见 docs/阅读页实现说明.md「@State private selStart: number = 0;」
  @State private selStart: number = 0;
  @State private selEnd: number = 0;
  // 说明见 docs/阅读页实现说明.md「private touchDownAt: number = 0;」
  private touchDownAt: number = 0;
  // 说明见 docs/阅读页实现说明.md「private volumeKeyUnregister: (() => void) | null = null;」
  private volumeKeyUnregister: (() => void) | null = null;
  // 说明见 docs/阅读页实现说明.md「private windowEffectsReset: boolean = false;」
  private windowEffectsReset: boolean = false;
  // 说明见 docs/阅读页实现说明.md「private bookmarkDraft: BookmarkDraft = new BookmarkDraft();」
  private bookmarkDraft: BookmarkDraft = new BookmarkDraft();
  // 说明见 docs/阅读页实现说明.md「private annotationMode: string = 'bookmark';」
  private annotationMode: string = 'bookmark';

  aboutToAppear(): void {
    this.state = this.vm.state;
    // 说明见 docs/阅读页实现说明.md「this.vm.setMeasureFn((segment: string, width: number): number => {」
    this.vm.setMeasureFn((segment: string, width: number): number => {
      if (segment.length === 0) {
        return 0;
      }
      const s = this.state.settings;
      const size = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: segment,
        // 宽度按 vp 传入（number 即 vp），与渲染端 width('100%') 的可用宽度一致
        constraintWidth: width,
        fontSize: s.fontSize,
        lineHeight: s.fontSize * s.lineHeight,
        letterSpacing: s.letterSpacing,
        // 说明见 docs/阅读页实现说明.md「fontFamily: ReaderSettings.resolveFontFamily(s.fontFamily),」
        fontFamily: ReaderSettings.resolveFontFamily(s.fontFamily),
        textIndent: 0
      });
      // px → vp：这一步不能省，否则高度会虚高约 3 倍
      return this.getUIContext().px2vp(Number(size.height));
    });
    // ⚠️ 用 UIContext 上的 Router，不用 @ohos.router 的全局函数 ——
    // 后者（pushUrl/replaceUrl/back/getParams）自 API 18 起全部废弃
    // （@ohos.router.d.ts:431/632/759 等），查询接口在
    // @ohos.arkui.UIContext.d.ts 的 class Router 上（getParams: :649）。
    const params = this.getUIContext().getRouter().getParams() as RouteParam | null;
    const bookId: number = params !== null && params !== undefined ? params.bookId : 0;
    if (bookId <= 0) {
      this.state.error = '缺少书籍参数，无法打开';
      this.state.loading = false;
      return;
    }
    this.vm.open(bookId).then(() => {
      // 说明见 docs/阅读页实现说明.md「if (this.state.settings.pageMode === 'scroll') {」
      if (this.state.settings.pageMode === 'scroll') {
        this.requestScrollRestore(this.state.offset);
        this.scheduleScrollRestore();
      }
      this.tryPaginate();
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `打开阅读页失败: ${e.message}`);
    });
  }

  // 说明见 docs/阅读页实现说明.md「onPageHide(): void {」
  onPageHide(): void {
    this.vm.onBackground().catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `离开阅读页落盘失败: ${e.message}`);
    });
  }

  aboutToDisappear(): void {
    // ⚠️ 先置"已离开"标记，再注销音量键监听：
    // 若注册回调还悬在半路（await 取窗口中），它看到标记会自我注销，
    // 不会留下一个页面销毁后仍存活的窗口监听。
    this.windowEffectsReset = true;
    this.unregisterVolumeKeyPaging();
    // 必须释放：结算阅读时长 + 关闭文件句柄
    this.vm.close().then(() => {
      this.vm.dispose();
    }).catch(() => {
      this.vm.dispose();
    });
    // ⚠️ 必须恢复窗口级设置：常亮与手动亮度都是**窗口属性**，
    // 不恢复的话退到书架后屏幕仍常亮、亮度仍停在手动值。
    // 传"关闭常亮 + 跟随系统亮度"，让窗口回到无定制状态。
    this.resetWindowEffects();
  }

  // 说明见 docs/阅读页实现说明.md「private resetWindowEffects(): void {」
  private resetWindowEffects(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    ReaderWindowEffects.applyKeepScreenOn(context, false).catch(() => {
    });
    ReaderWindowEffects.applyBrightness(context, -1).catch(() => {
    });
    // 状态栏必须恢复显示：隐藏是阅读页的定制，退到书架后系统条要回来
    ReaderWindowEffects.applySystemBarsVisible(context, true).catch(() => {
    });
  }

  // 说明见 docs/阅读页实现说明.md「onPageShow(): void {」
  onPageShow(): void {
    // 说明见 docs/阅读页实现说明.md「this.applyWindowEffects(this.state.settings);」
    this.applyWindowEffects(this.state.settings);

    // 说明见 docs/阅读页实现说明.md「this.vm.refreshHighlights().catch((e: Object) => {」
    this.vm.refreshHighlights().catch((e: Object) => {
      Logger.warn(LogTag.READ, `刷新划线失败: ${Logger.errText(e)}`);
    });

    const jump: ReaderJump | null = ReaderJumpRegistry.consume();
    if (jump === null) {
      return;
    }
    // -1 表示"未指定偏移" → 落到章首。
    // ⚠️ 不能把 -1 直接传给 switchChapter：那里 -1 的含义是"定位到章末"。
    const toOffset: number = jump.offset < 0 ? 0 : jump.offset;
    this.vm.switchChapter(jump.chapterIndex, toOffset).then(() => {
      // 说明见 docs/阅读页实现说明.md「if (this.state.settings.pageMode === 'scroll') {」
      if (this.state.settings.pageMode === 'scroll') {
        if (toOffset > 0) {
          // 指定了章内偏移（书签）：登记目标，等新内容布局完成后滚过去
          this.requestScrollRestore(toOffset);
          this.scheduleScrollRestore();
        } else {
          // 只选章（目录里点章节名）：回到章首，与分页模式的行为对齐
          this.resetScrollAfterChapterChange();
        }
      } else {
        // 分页/平移：换章后相邻槽位的预渲染文本必须跟着新章刷新
        this.refreshSlideSlots();
      }
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `跳章失败: ${e.message}`);
    });
  }

  private openCatalog(): void {
    const param = new RouteParam();
    param.bookId = this.state.book !== null ? this.state.book.id : 0;
    // 传当前章进去，目录页打开时才能自动滚到当前位置
    param.chapterIndex = this.state.chapterIndex;
    this.getUIContext().getRouter().pushUrl({
      url: RouteName.READER_CATALOG_PAGE,
      params: param
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `打开目录页失败: ${e.message}`);
    });
  }

  // 说明见 docs/阅读页实现说明.md「private doRefresh(): void {」
  private doRefresh(): void {
    this.vm.refreshCurrentChapter().then(() => {
      // 说明见 docs/阅读页实现说明.md「this.restoreScrollToCurrentOffset();」
      this.restoreScrollToCurrentOffset();
      this.toast('已刷新');
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `刷新阅读页失败: ${e.message}`);
      this.toast('刷新失败');
    });
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private tryPaginate(): void {
    if (this.pageAreaHeight <= 0 || this.contentWidth <= 0) {
      return;
    }
    // 说明见 docs/阅读页实现说明.md「const bodyWidth: number = this.measureWidth();」
    const bodyWidth: number = this.measureWidth();
    Logger.info(LogTag.READ,
      `分页尺寸: 容器w=${this.contentWidth.toFixed(1)} 正文w=${bodyWidth.toFixed(1)}`
        + ` h=${this.pageAreaHeight.toFixed(1)}`
        + ` 标题占位=${this.headingHeight().toFixed(1)}`
        + ` 字号=${this.state.settings.fontSize} 行距=${this.state.settings.lineHeight}`);
    this.vm.setContentSize(bodyWidth, this.pageAreaHeight, this.headingHeight());

    // 说明见 docs/阅读页实现说明.md「if (this.state.settings.pageMode !== 'scroll') {」
    if (this.state.settings.pageMode !== 'scroll') {
      // ===== 诊断日志（定位"跨章闪一下"，问题解决后移除）=====
      Logger.info('SlideDiag', `[T0] tryPaginate → repaginate 章=${this.state.chapterIndex}`
        + ` t=${Date.now() % 100000}`);
      this.vm.repaginateCurrentChapter().then(() => {
        // 重排后页边界可能变化：平移相邻槽位的预渲染文本同步刷新
        this.refreshSlideSlots();
      }).catch((e: Object) => {
        Logger.error(LogTag.READ, `重排当前章失败: ${Logger.errText(e)}`);
      });
    }
  }

  private theme(): ReaderTheme {
    // 说明见 docs/阅读页实现说明.md「return ReaderTheme.of(this.state.settings.theme, this.appDarkMode);」
    return ReaderTheme.of(this.state.settings.theme, this.appDarkMode);
  }

  // 说明见 docs/阅读页实现说明.md「private footerTotalHeight(): number {」
  private footerTotalHeight(): number {
    return AppTheme.READER_FOOTER_HEIGHT + Math.max(0, this.safeAreaBottom);
  }

  build() {
    Stack() {
      // 说明见 docs/阅读页实现说明.md「Column() {」
      Column() {
        // 说明见 docs/阅读页实现说明.md「if (this.safeAreaTop > 0) {」
        if (this.safeAreaTop > 0) {
          Row()
            .width('100%')
            .height(this.safeAreaTop)
        }

        Column() {
          if (this.state.loading) {
            LoadingView({ message: '正在打开…' })
          } else if (this.state.error.length > 0) {
            ErrorView({
              message: this.state.error,
              hint: '可返回书架后重新导入这本书',
              actionText: '返回书架',
              onRetry: () => {
                this.goBack();
              }
            })
          } else {
            this.buildReaderBody()
          }
        }
        .width('100%')
        // 正文占满"减去底栏"的剩余空间（不能用 height('100%')，那会溢出）
        .layoutWeight(1)
        // 量出分页可用的**恒定**高度（见 pageAreaHeight 的说明）
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.onPageAreaChange(newArea);
        })

        // 说明见 docs/阅读页实现说明.md「ReaderFooterBar({」
        ReaderFooterBar({
          chapterTitle: this.headingText(),
          pageText: this.state.pageText,
          progressText: this.state.progressText,
          theme: this.theme(),
          safeAreaBottom: this.safeAreaBottom,
          totalHeight: this.footerTotalHeight()
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme().bg)

      // 说明见 docs/阅读页实现说明.md「if (!this.state.menuVisible && !this.state.settingsVisible」
      if (!this.state.menuVisible && !this.state.settingsVisible
        && this.state.error.length === 0 && !this.state.loading
        && this.state.settings.pageMode === 'page') {
        this.buildPageControls()
      }

      // 第 3 层：顶栏 / 底栏（只在菜单显示时出现，且位于翻页层之上）
      if (this.state.menuVisible && this.state.error.length === 0) {
        ReaderMenuLayer({
          // 顶栏中间显示书名（`state.book` 打开中可能为 null）
          title: this.state.book !== null ? this.state.book.title : '',
          theme: this.theme(),
          percent: this.state.percent,
          hasPrev: this.state.hasPrev,
          hasNext: this.state.hasNext,
          safeAreaBottom: this.safeAreaBottom,
          safeAreaTop: this.safeAreaTop,
          appDarkMode: this.appDarkMode,
          onBack: () => {
            this.goBack();
          },
          onRefresh: () => {
            this.doRefresh();
          },
          onHideMenu: () => {
            this.vm.hideMenu();
            // hideMenu 会连带收掉设置面板 —— 本地镜像同步，
            // 否则状态已 false 而 sheet 还开着（下次点"设置"没反应）
            this.sheetShow = false;
            this.syncWindowChrome();
          },
          onJump: (percent: number) => {
            this.vm.jumpToChapterByPercent(percent).then(() => {
              this.resetScrollAfterChapterChange();
              this.refreshSlideSlots();
            }).catch((e: Object) => {
              Logger.error(LogTag.READ, `进度条跳章失败: ${Logger.errText(e)}`);
            });
          },
          onPrevChapter: () => {
            this.vm.prevChapter().then(() => {
              this.resetScrollAfterChapterChange();
              this.refreshSlideSlots();
            }).catch((e: Object) => {
              Logger.error(LogTag.READ, `上一章失败: ${Logger.errText(e)}`);
            });
          },
          onNextChapter: () => {
            this.vm.nextChapter().then(() => {
              this.resetScrollAfterChapterChange();
              this.refreshSlideSlots();
            }).catch((e: Object) => {
              Logger.error(LogTag.READ, `下一章失败: ${Logger.errText(e)}`);
            });
          },
          onOpenCatalog: () => {
            this.openCatalog();
          },
          // 切换**整个 app** 的深浅色，不是阅读页正文背景（那是"设置"里的主题）
          onToggleNight: () => {
            if (!this.vm.toggleAppTheme()) {
              this.toast('切换夜间模式失败');
            }
          },
          onOpenSettings: () => {
            this.vm.setSettingsVisible(true);
            // 本地镜像同步拉起 sheet（bindSheet 的 isShow 读它）
            this.sheetShow = true;
            this.syncWindowChrome();
          }
        })
      }

  // 说明见 docs/阅读页实现说明.md「if (this.state.bookmarkVisible && this.state.error.length === 0) {」

      // 说明见 docs/阅读页实现说明.md「if (this.state.bookmarkVisible && this.state.error.length === 0) {」
      if (this.state.bookmarkVisible && this.state.error.length === 0) {
        ReaderBookmarkLayer({
          draft: this.bookmarkDraft,
          theme: this.theme(),
          mode: this.annotationMode,
          onSave: (note: string) => {
            // 按 `annotationMode` 分流到两个保存方法：它们写的标注类型不同
            // （bookmark / note），混在一起会让"保存成功"的文案说不清存了什么
            if (this.annotationMode === 'note') {
              this.saveNote(note);
            } else {
              this.saveBookmark(note);
            }
          },
          onCancel: () => {
            this.vm.setBookmarkVisible(false);
            this.syncWindowChrome();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    // 说明见 docs/阅读页实现说明.md「.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])」
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 说明见 docs/阅读页实现说明.md「.bindSheet(this.sheetShow, this.settingsSheetBuilder(), {」
    .bindSheet(this.sheetShow, this.settingsSheetBuilder(), {
      height: this.sheetHeight(),
      preferType: SheetType.BOTTOM,
      dragBar: false,
      showClose: false,
      onDisappear: () => {
        // 系统侧关闭（点蒙层 / 下滑手势）：回写状态，否则
        // "设置"入口点了没反应（settingsVisible 还停在 true）
        if (this.state.settingsVisible) {
          this.vm.setSettingsVisible(false);
        }
        this.sheetShow = false;
        this.syncWindowChrome();
      }
    })
  }

  // 说明见 docs/阅读页实现说明.md「@State private sheetShow: boolean = false;」
  @State private sheetShow: boolean = false;

  // 说明见 docs/阅读页实现说明.md「private sheetHeight():  Length {」
  private sheetHeight():  Length {
    return '70%';
  }

  @Builder
  settingsSheetBuilder() {
    ReaderSettingsSheet({
      settings: this.state.settings,
      theme: this.theme(),
      safeAreaBottom: this.safeAreaBottom,
      // 就地生效：改完立刻重排，用户能直接看着正文调
      onChange: (next: ReaderSettings) => {
        this.vm.updateSettings(next).then(() => {
          // ⚠️ 改排版后必须按当前偏移重新对齐：滚动容器的偏移还停在旧排版上。
          // 这里**不能**走 `resetScrollAfterChapterChange()` ——
          // 改字号/行距不该改变阅读位置，回到章首或章末都是错的。
          this.restoreScrollToCurrentOffset();
          // ⚠️ 窗口级设置（亮度/常亮）跟着应用；它异步且可能被系统拒绝，
          // 所以不阻塞 updateSettings 这条链，只记日志。
          this.applyWindowEffects(next);
        }).catch((e: Object) => {
          Logger.error(LogTag.READ, `应用阅读设置失败: ${Logger.errText(e)}`);
        });
      },
      onClose: () => {
        this.vm.setSettingsVisible(false);
        this.sheetShow = false;
        this.syncWindowChrome();
      }
    })
  }

  // 常驻底栏已拆到 views/reader/ReaderPageParts.ets 的 `ReaderFooterBar`；
  // 本文件只保留 `footerTotalHeight()`（菜单栏要与它用同一个总高）。

  @Builder
  buildPageControls() {
    Row() {
      Column()
        .width('33%')
        .height('100%')
        .onClick(() => {
          this.handleReaderTap('prev');
        })

      Column()
        .width('34%')
        .height('100%')
        .onClick(() => {
          this.handleReaderTap('menu');
        })

      Column()
        .width('33%')
        .height('100%')
        .onClick(() => {
          this.handleReaderTap('next');
        })
    }
    .width('100%')
    .height('100%')
    // 说明见 docs/阅读页实现说明.md「.hitTestBehavior(HitTestMode.Transparent)」
    .hitTestBehavior(HitTestMode.Transparent)
    // 记录按下时刻：`handleReaderTap` 靠它区分"点击"与"长按"
    // （长按选中正文后松手时，三个分区的 onClick 也会触发）
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.touchDownAt = Date.now();
      }
    })
    // 说明见 docs/阅读页实现说明.md「.gesture(」
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionEnd((event: GestureEvent) => {
          if (this.state.settings.pageMode === 'slide') {
            return; // 平移翻页：滑动手势归 Swiper，这里只承担点击分区
          }
          // 说明见 docs/阅读页实现说明.md「if (this.hasSelection) {」
          if (this.hasSelection) {
            return;
          }
          const dx: number = event.offsetX;
          if (dx <= -AppConstants.PAGE_SWIPE_MIN_DISTANCE) {
            this.turnPageByUi(true);
          } else if (dx >= AppConstants.PAGE_SWIPE_MIN_DISTANCE) {
            this.turnPageByUi(false);
          }
        })
    )
  }

  // ------------------------------------------------------------ 正文

  // 说明见 docs/阅读页实现说明.md「private applyWindowEffects(settings: ReaderSettings): void {」
  private applyWindowEffects(settings: ReaderSettings): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    ReaderWindowEffects.applyBrightness(context, settings.brightness).catch(() => {
      // 内部已记日志，这里只是把 Promise 收干净，避免未处理的拒绝
    });
    ReaderWindowEffects.applyKeepScreenOn(context, settings.keepScreenOn).catch(() => {
      // 同上：内部已记日志
    });
    // 状态栏显隐：按"设置 + 当前浮层状态"决定（面板里刚改过也能立即生效）。
    // 走 syncWindowChrome 而不是直接调 API：它同时把音量键监听也按新设置重建。
    this.syncWindowChrome();
  }

  // 说明见 docs/阅读页实现说明.md「private applyVolumeKeyPaging(enabled: boolean): void {」
  private applyVolumeKeyPaging(enabled: boolean): void {
    // 先摘旧的（若有）
    this.unregisterVolumeKeyPaging();
    if (!enabled) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    ReaderWindowEffects.registerVolumeKeyPaging(
      context,
      (): void => {
        // 音量减 = 上一页（与"左 1/3 屏"方向一致的直觉）
        this.turnPageByUi(false);
      },
      (): void => {
        // 音量加 = 下一页
        this.turnPageByUi(true);
      }
    ).then((unregister: (() => void) | null) => {
      // ⚠️ await 期间用户可能已离开本页（aboutToDisappear 已跑过）：
      // 此时注销表已由离开路径处理过，这里若再存下注销函数，
      // 这个晚到的注册就成了泄漏源 —— 检查"已离开"标记再决定收不收。
      if (this.windowEffectsReset) {
        if (unregister !== null) {
          unregister();
        }
        return;
      }
      this.volumeKeyUnregister = unregister;
      // 注册完成时菜单可能已经弹出来了（注册是异步的）：
      // 按注册时的最新浮层状态决定要不要立刻挂起。
      if (this.isOverlayShowing()) {
        this.syncWindowChrome();
      }
    }).catch(() => {
      // 内部已记日志
    });
  }

  // 说明见 docs/阅读页实现说明.md「private isOverlayShowing(): boolean {」
  private isOverlayShowing(): boolean {
    return this.state.menuVisible || this.state.settingsVisible
      || this.state.bookmarkVisible;
  }

  // 说明见 docs/阅读页实现说明.md「private syncVolumeKeyPaging(): void {」
  private syncVolumeKeyPaging(): void {
    if (this.isOverlayShowing()) {
      this.unregisterVolumeKeyPaging();
    } else if (this.state.settings.volumeKeyPage && !this.windowEffectsReset) {
      this.applyVolumeKeyPaging(true);
    }
  }

  // 说明见 docs/阅读页实现说明.md「private syncWindowChrome(): void {」
  private syncWindowChrome(): void {
    this.syncVolumeKeyPaging();
    const context = this.getUIContext().getHostContext();
    if (context === undefined || this.windowEffectsReset) {
      return;
    }
    const hide: boolean = this.state.settings.hideStatusBar && !this.isOverlayShowing();
    ReaderWindowEffects.applySystemBarsVisible(context, !hide).catch(() => {
      // 内部已记日志
    });
  }

  private unregisterVolumeKeyPaging(): void {
    if (this.volumeKeyUnregister !== null) {
      const unregister: (() => void) | null = this.volumeKeyUnregister;
      this.volumeKeyUnregister = null;
      unregister();
    }
  }

  // 说明见 docs/阅读页实现说明.md「private buildTextRuns(): TextRun[] {」
  private buildTextRuns(): TextRun[] {
    return this.vm.buildTextRuns(this.state.highlights);
  }

  // 说明见 docs/阅读页实现说明.md「private buildTextEditMenu(): EditMenuOptions {」
  private buildTextEditMenu(): EditMenuOptions {
    const bookmarkId: TextMenuItemId = TextMenuItemId.of('reader_bookmark');
    const highlightId: TextMenuItemId = TextMenuItemId.of('reader_highlight');
    const noteId: TextMenuItemId = TextMenuItemId.of('reader_note');
    // 说明见 docs/阅读页实现说明.md「const options: EditMenuOptions = {」
    const options: EditMenuOptions = {
      onCreateMenu: (menuItems: Array<TextMenuItem>): Array<TextMenuItem> => {
        // 说明见 docs/阅读页实现说明.md「const bookmark: TextMenuItem = { content: '书签', id: bookmarkId };」
        const bookmark: TextMenuItem = { content: '书签', id: bookmarkId };
        const highlight: TextMenuItem = { content: '划线', id: highlightId };
        const note: TextMenuItem = { content: '笔记', id: noteId };
        const mine: Array<TextMenuItem> = [bookmark, highlight, note];

        // 说明见 docs/阅读页实现说明.md「const kept: Array<TextMenuItem> = [];」
        const kept: Array<TextMenuItem> = [];
        for (const item of menuItems) {
          if (item.id.equals(TextMenuItemId.COPY)
            || item.id.equals(TextMenuItemId.SELECT_ALL)
            || item.id.equals(TextMenuItemId.SEARCH)) {
            kept.push(item);
          }
        }
        return mine.concat(kept);
      },
      onMenuItemClick: (menuItem: TextMenuItem, range: TextRange): boolean => {
        const start: number = range.start ?? 0;
        const end: number = range.end ?? start;

        // 说明见 docs/阅读页实现说明.md「this.clearSelection();」
        this.clearSelection();

        const id: TextMenuItemId = menuItem.id;
        const isBookmark: boolean = id.equals(bookmarkId);
        const isHighlight: boolean = id.equals(highlightId);
        const isNote: boolean = id.equals(noteId);
        const isCopy: boolean = id.equals(TextMenuItemId.COPY);
        // 说明见 docs/阅读页实现说明.md「setTimeout(() => {」
        setTimeout(() => {
          if (isBookmark) {
            this.openBookmarkDialog(start, end);
          } else if (isHighlight) {
            this.saveHighlight(start, end);
          } else if (isNote) {
            this.openNoteDialog(start, end);
          } else if (isCopy) {
            this.copySelection(start, end);
          }
        }, AppConstants.READER_MENU_DISMISS_MS);

        // 说明见 docs/阅读页实现说明.md「return isBookmark || isHighlight || isNote || isCopy;」
        return isBookmark || isHighlight || isNote || isCopy;
      }
    };
    return options;
  }

  // 说明见 docs/阅读页实现说明.md「private clearSelection(): void {」
  private clearSelection(): void {
    this.textController.closeSelectionMenu();
    this.hasSelection = false;
    // 把选区端点压成 (0, 0)：文档明确 start >= end 时"不选中任何文字"，
    // 配合 @State 触发的那次重绘，高亮与手柄才会真正消失
    this.selStart = 0;
    this.selEnd = 0;
  }

  // 说明见 docs/阅读页实现说明.md「private handleReaderTap(action: string): void {」
  private handleReaderTap(action: string): void {
    // 说明见 docs/阅读页实现说明.md「const heldMs: number = Date.now() - this.touchDownAt;」
    const heldMs: number = Date.now() - this.touchDownAt;
    if (this.touchDownAt > 0 && heldMs > AppConstants.READER_TAP_MAX_MS) {
      return;
    }

    if (this.hasSelection) {
      this.clearSelection();
      return;
    }
    if (action === 'prev') {
      this.turnPageByUi(false);
    } else if (action === 'next') {
      this.turnPageByUi(true);
    } else {
      this.vm.toggleMenu();
      this.syncWindowChrome();
    }
  }

  // 说明见 docs/阅读页实现说明.md「private turnPageByUi(forward: boolean): void {」
  private turnPageByUi(forward: boolean): void {
    if (this.state.settings.pageMode === 'slide' && !this.slideAnimating) {
      // 说明见 docs/阅读页实现说明.md「this.swiperController.changeIndex(forward ? 2 : 0, true);」
      this.swiperController.changeIndex(forward ? 2 : 0, true);
      return;
    }
    if (forward) {
      this.vm.nextPage();
    } else {
      this.vm.prevPage();
    }
  }

  // 说明见 docs/阅读页实现说明.md「private copySelection(renderedStart: number, renderedEnd: number): void {」
  private copySelection(renderedStart: number, renderedEnd: number): void {
    const startOriginal: number = this.vm.toOriginalOffset(renderedStart);
    const endOriginal: number = this.vm.toOriginalOffset(renderedEnd);
    const text: string = this.vm.originalTextBetween(startOriginal, endOriginal);
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({ message: '已复制' });
    } catch (e) {
      Logger.error(LogTag.READ, `复制失败: ${Logger.errText(e as Object)}`);
      this.getUIContext().getPromptAction().showToast({ message: '复制失败' });
    }
  }

  // 说明见 docs/阅读页实现说明.md「private openBookmarkDialog(renderedStart: number, renderedEnd: number): void {」
  private openBookmarkDialog(renderedStart: number, renderedEnd: number): void {
    const startOriginal: number = this.vm.toOriginalOffset(renderedStart);
    const endOriginal: number = this.vm.toOriginalOffset(renderedEnd);
    this.bookmarkDraft = this.vm.buildBookmarkDraft(startOriginal, endOriginal);
    this.annotationMode = 'bookmark';
    this.vm.setBookmarkVisible(true);
    this.syncWindowChrome();
  }

  // 说明见 docs/阅读页实现说明.md「private openNoteDialog(renderedStart: number, renderedEnd: number): void {」
  private openNoteDialog(renderedStart: number, renderedEnd: number): void {
    const startOriginal: number = this.vm.toOriginalOffset(renderedStart);
    const endOriginal: number = this.vm.toOriginalOffset(renderedEnd);
    this.bookmarkDraft = this.vm.buildAnnotationDraft(startOriginal, endOriginal);
    this.annotationMode = 'note';
    this.vm.setBookmarkVisible(true);
    this.syncWindowChrome();
  }

  // 说明见 docs/阅读页实现说明.md「private saveHighlight(renderedStart: number, renderedEnd: number): void {」
  private saveHighlight(renderedStart: number, renderedEnd: number): void {
    const startOriginal: number = this.vm.toOriginalOffset(renderedStart);
    const endOriginal: number = this.vm.toOriginalOffset(renderedEnd);
    this.vm.addHighlight(startOriginal, endOriginal).then((id: number) => {
      this.toast(id > 0 ? '已划线' : '划线失败：请选中一段文字');
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `划线失败: ${e.message}`);
      this.toast('划线失败');
    });
  }

  private saveBookmark(note: string): void {
    // 把用户填的备注并进草稿（草稿是深拷贝，这里改的是页面自己那份）
    this.bookmarkDraft.note = note;
    this.vm.saveBookmark(this.bookmarkDraft).then((result: BookmarkSaveResult) => {
      this.vm.setBookmarkVisible(false);
      this.syncWindowChrome();
      if (!result.ok) {
        // ⚠️ 失败必须单独提示，否则用户以为存上了
        this.getUIContext().getPromptAction().showToast({ message: '书签保存失败' });
        return;
      }
      // 区分"新建"与"覆盖"：用户刚在同位置存过时，明确告诉他旧的那条被替换了
      this.getUIContext().getPromptAction().showToast({
        message: result.updated ? '已更新该书签' : '已添加书签'
      });
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `保存书签失败: ${e.message}`);
    });
  }

  // 说明见 docs/阅读页实现说明.md「private saveNote(note: string): void {」
  private saveNote(note: string): void {
    const draft: BookmarkDraft = this.bookmarkDraft;
    const startOriginal: number = draft.startOffset;
    // draft.endOffset 为 -1 表示没有具体区间（只记一个点），此时用起点兜底
    const endOriginal: number = draft.endOffset >= 0 ? draft.endOffset : startOriginal;
    this.vm.addNote(startOriginal, endOriginal, note).then((id: number) => {
      this.vm.setBookmarkVisible(false);
      this.syncWindowChrome();
      this.getUIContext().getPromptAction().showToast({
        message: id > 0 ? '已保存笔记' : '笔记保存失败'
      });
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `保存笔记失败: ${e.message}`);
      this.getUIContext().getPromptAction().showToast({ message: '笔记保存失败' });
    });
  }

  // 说明见 docs/阅读页实现说明.md「private headingText(): string {」
  private headingText(): string {
    if (this.state.chapterTitle.length > 0) {
      return this.state.chapterTitle;
    }
    const index: number = this.state.chapterIndex;
    if (index < 0 || index >= this.state.chapters.length) {
      return '';
    }
    return `第 ${this.state.chapters[index].displayNumber()} 章`;
  }

  private headingLineHeight(): number {
    return (this.state.settings.fontSize + AppTheme.SIZE_STEP) * this.state.settings.lineHeight;
  }

  // 说明见 docs/阅读页实现说明.md「private headingHeight(): number {」
  private headingHeight(): number {
    return this.headingLineHeight() + AppTheme.GAP_S + AppTheme.GAP_M;
  }

  // 说明见 docs/阅读页实现说明.md「@Builder」
  // 章节标题的渲染已拆到 views/reader/ReaderPageParts.ets 的 `ReaderChapterHeading`：
  // 那里保留了"题花线必须叠在下内边距之内、总高一个 vp 都不能变"的约束说明。
  // 本文件只保留它的**高度算术**（headingText / headingLineHeight / headingHeight）。

  // 说明见 docs/阅读页实现说明.md「@Builder」
  @Builder
  buildScrollSection(section: ScrollSection) {
    Column() {
      // 章间分隔线（第一块上面不画：它上面要么是屏幕顶、要么无上一章）
      if (section.chapterIndex > 0) {
        Row()
          .width('100%')
          .height(AppTheme.HAIRLINE)
          .backgroundColor(this.theme().secondary)
          .opacity(AppTheme.READER_RULE_ALPHA)
          .margin({ top: AppTheme.GAP_L * 2, bottom: AppTheme.GAP_L * 2 })
      }

      // 章节标题（复用与分页模式同一套标题样式）
      Text(section.title.length > 0 ? section.title : `第 ${section.chapterIndex + 1} 章`)
        .fontSize(this.state.settings.fontSize + AppTheme.SIZE_STEP)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme().text)
        .fontFamily(ReaderSettings.resolveFontFamily(this.state.settings.fontFamily))
        .letterSpacing(AppTheme.TRACK_CHAPTER)
        .lineHeight(this.headingLineHeight())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ top: AppTheme.GAP_S, bottom: AppTheme.GAP_M })

      // 说明见 docs/阅读页实现说明.md「if (section.isCurrent) {」
      if (section.isCurrent) {
        Text('', { controller: this.textController }) {
          ForEach(this.buildTextRuns(), (run: TextRun) => {
            if (run.highlighted) {
              Span(run.text)
                .textBackgroundStyle(AppTheme.highlightSpanStyle())
            } else {
              Span(run.text)
            }
          }, (run: TextRun, index: number) => `s${index}_${run.highlighted}_${run.text.length}`)
        }
          .fontSize(this.state.settings.fontSize)
          .fontColor(this.theme().text)
          .fontFamily(ReaderSettings.resolveFontFamily(this.state.settings.fontFamily))
          .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
          .letterSpacing(this.state.settings.letterSpacing)
          .textIndent(0)
          .width('100%')
          .copyOption(CopyOptions.InApp)
          .editMenuOptions(this.buildTextEditMenu())
          .selection(this.selStart, this.selEnd)
          .onTextSelectionChange((start: number, end: number) => {
            this.hasSelection = end > start;
            this.selStart = start;
            this.selEnd = end;
          })
      } else {
        Text() {
          Span(section.decoratedText)
        }
          .fontSize(this.state.settings.fontSize)
          .fontColor(this.theme().text)
          .fontFamily(ReaderSettings.resolveFontFamily(this.state.settings.fontFamily))
          .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
          .letterSpacing(this.state.settings.letterSpacing)
          .textIndent(0)
          .width('100%')
      }
    }
    .width('100%')
    // 记录每块的实际高度：视口顶部落在哪一章由这些实测值算出
    // （估算行数会随空行/标题高度漂移，实测一次就准）
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.recordSectionHeight(section.chapterIndex, Number(newArea.height));
    })
  }

  @Builder
  buildReaderBody() {
    // 说明见 docs/阅读页实现说明.md「Column() {」
    Column() {
      if (this.state.settings.pageMode === 'scroll') {
      // 滚动模式：**连续窗口**——上一章 + 当前章 + 下一章铺在同一股滚动流里，
      // 向上滑能看到上一章结尾、越过边界直接滑进下一章，全程无"换内容"。
      Scroll(this.scroller) {
        Column() {
          ForEach(this.state.scrollSections, (section: ScrollSection) => {
            this.buildScrollSection(section)
          }, (section: ScrollSection) =>
            // ⚠️ 键必须带窗口代数：窗口平移时同一章会以"新内容"重新入列，
            // 复用旧实例会显示旧排版（代数变了键就变，强制重建）
            `sec_${this.state.scrollWindowRev}_${section.chapterIndex}`)
        }
        .width('100%')
        // ⚠️ 左右页边距必须**真的**加在渲染上，否则与分页算的宽度对不上：
        // 分页按"容器宽度 − 2×pageMargin"算每行字数，渲染却铺满全宽，
        // 结果每行实际能放更多字 ⇒ 每页末尾被裁掉几行。
        .padding({ left: this.state.settings.pageMargin, right: this.state.settings.pageMargin })
        // 量的是"全部章节块"的**内容总高度**：滚动上限判断、位置恢复都要它
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.onScrollContentChange(newArea);
        })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      // 用 layoutWeight 而不是 height('100%')：百分比取的是**父容器**高度，
      // 一旦以后在正文之上再放常驻元素（页眉/工具栏），"元素 + 100%"就会溢出屏幕，
      // Scroll 底部一段永远滚不到。layoutWeight 取的是真正的剩余空间。
      .layoutWeight(1)
      // 量出可视高度：判断"能不能滚"、视口顶部落在哪一章都要它
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.viewportHeight = Number(newArea.height);
        // 说明见 docs/阅读页实现说明.md「this.applyPendingScrollRestore();」
        this.applyPendingScrollRestore();
      })
      // 说明见 docs/阅读页实现说明.md「.parallelGesture(」
      .parallelGesture(
        TapGesture()
          .onAction(() => {
            // 与分页模式一致：有选中时这一下只用来取消选择，不切菜单
            this.handleReaderTap('menu');
          })
      )
      // 记录按下时刻：`handleReaderTap` 靠它区分"点击"与"长按"
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.touchDownAt = Date.now();
        }
      })
      // 说明见 docs/阅读页实现说明.md「.onScroll(() => {」
      .onScroll(() => {
        this.onReaderScroll();
      })
    } else if (this.state.settings.pageMode === 'slide') {
      // 平移翻页：与 page 完全同源的分页数据（breaks / renderedText），
      // 只是渲染外套一层 Swiper 提供平移过渡。
      this.buildSlideBody()
    } else {
      // 分页模式：标题只出现在本章第一页。首页让位的那一截高度
      // 已通过 setContentSize(..., headingHeight()) 交给分页服务扣除，
      // 所以这里直接渲染不会把首页最后一行挤掉。
      this.buildPagedPage()
    }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // 说明见 docs/阅读页实现说明.md「@Builder」
  @Builder
  buildSlideBody() {
    Swiper(this.swiperController) {
      // ⚠️ 各槽包一层带 `.id()` 的 Column：id 含内容代数（slidePageRev）与章号，
      // 翻页/换章后 id 变 ⇒ 三个槽位**整体重建** —— 不重建的话，同构子树被
      // 局部复用，标题条件块会丢（实测 bug）。章号进 id 是因为跨章翻页
      // 不经过 Swiper onChange（是 vm 内部换章）。
      Column() {
        this.buildSlidePrevSlot()
      }
      .width('100%')
      .height('100%')
      .id(`slide_p_${this.state.chapterIndex}_${this.slidePageRev}`)

      Column() {
        this.buildPagedPage()
      }
      .width('100%')
      .height('100%')
      .id(`slide_c_${this.state.chapterIndex}_${this.slidePageRev}`)

      Column() {
        this.buildSlideNextSlot()
      }
      .width('100%')
      .height('100%')
      .id(`slide_n_${this.state.chapterIndex}_${this.slidePageRev}`)
    }
    .index(1)
    .loop(false)
    .indicator(false)
    .duration(AppConstants.SLIDE_ANIM_DURATION_MS)
    .curve(Curve.Friction)
    .width('100%')
    .layoutWeight(1)
    .onChange((index: number) => {
      // 说明见 docs/阅读页实现说明.md「if (index === 1) {」
      if (index === 1) {
        return; // 回弹（滑一半松手弹回中间）：无事发生
      }
      if (this.slideAnimating) {
        // 处理中途又收到一次非 1 索引：先把它拉回中间，别让 Swiper 停在 0/2
        this.swiperController.changeIndex(1, false);
        return;
      }
      this.slideAnimating = true;
      const forward: boolean = index > 1;
      // ===== 诊断日志（定位"跨章闪一下"，问题解决后移除）=====
      Logger.info('SlideDiag', `[P0] Swiper onChange idx=${index} 翻${forward ? '后' : '前'}`
        + ` 章=${this.state.chapterIndex} t=${Date.now() % 100000}`);
      const turn: Promise<void> = forward ? this.vm.nextPage() : this.vm.prevPage();
      turn.finally(() => {
        // 说明见 docs/阅读页实现说明.md「this.slidePageRev += 1;」
        this.slidePageRev += 1;
        this.refreshSlideSlots();
        this.swiperController.changeIndex(1, false);
        this.slideAnimating = false;
        // ===== 诊断日志（定位"跨章闪一下"，问题解决后移除）=====
        Logger.info('SlideDiag', `[P1] 翻页完成+复位 章=${this.state.chapterIndex}`
          + ` 页=${this.state.pageIndex}/${this.state.pageCount} t=${Date.now() % 100000}`);
      });
    })
    // 说明见 docs/阅读页实现说明.md「.onTouch((event: TouchEvent) => {」
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.touchDownAt = Date.now();
        this.slideTouchX = event.touches[0].x;
      }
    })
    .parallelGesture(
      TapGesture()
        .onAction(() => {
          this.handleSlideTap();
        })
    )
  }

  // 说明见 docs/阅读页实现说明.md「private handleSlideTap(): void {」
  private handleSlideTap(): void {
    const x: number = this.slideTouchX;
    const bodyWidth: number = this.contentWidth > 0 ? this.contentWidth : 1;
    if (x < bodyWidth / 3) {
      this.handleReaderTap('prev');
    } else if (x > bodyWidth * 2 / 3) {
      this.handleReaderTap('next');
    } else {
      this.handleReaderTap('menu');
    }
  }

  // 说明见 docs/阅读页实现说明.md「private async refreshSlideSlots(): Promise<void> {」
  private async refreshSlideSlots(): Promise<void> {
    if (this.state.settings.pageMode !== 'slide') {
      return;
    }
    const prevIndex: number = this.state.pageIndex - 1;
    const nextIndex: number = this.state.pageIndex + 1;
    // 越界页码交给 pageTextFor 处理跨章；连跨章都越界（全书首/末页）得空串
    this.slidePrevText = await this.vm.pageTextFor(prevIndex);
    this.slideNextText = await this.vm.pageTextFor(nextIndex);
    // ===== 诊断日志（定位"跨章闪一下"，问题解决后移除）=====
    Logger.info('SlideDiag', `[P2] 槽位刷新 章=${this.state.chapterIndex}`
      + ` prev=${this.slidePrevText.length}字 next=${this.slideNextText.length}字`
      + ` t=${Date.now() % 100000}`);
    // 相邻槽是否落在"某章第一页"（决定画不画章节标题）：
    //  - 上一槽：本章第 0 页（当前在第 1 页时）→ 画；跨章时是上一章末尾 → 不画
    //  - 下一槽：跨章时是下一章第一页 → 画；本章内页码 > 0 → 不画
    this.slidePrevIsChapterHead = prevIndex === 0;
    this.slideNextIsChapterHead = nextIndex >= this.state.pageCount;
    // 相邻槽的标题：按槽位实际所属的章取，不读当前章标题（见字段说明）。
    // 跨章槽：prev = 上一章、next = 下一章；章内槽只有 prev 可能是本章首页。
    this.slidePrevTitle = this.slidePrevIsChapterHead
      ? this.titleOfChapter(this.state.chapterIndex)
      : '';
    this.slideNextTitle = this.slideNextIsChapterHead
      ? this.titleOfChapter(this.state.chapterIndex + 1)
      : '';
  }

  // 说明见 docs/阅读页实现说明.md「private titleOfChapter(index: number): string {」
  private titleOfChapter(index: number): string {
    if (index < 0 || index >= this.state.chapters.length) {
      return '';
    }
    const title: string = this.state.chapters[index].title;
    return title.length > 0 ? title : `第 ${this.state.chapters[index].displayNumber()} 章`;
  }

  // 说明见 docs/阅读页实现说明.md「@Builder」
  @Builder
  buildSlidePrevSlot() {
    Column() {
      if (this.slidePrevIsChapterHead) {
        // 上一槽恰是本章首页（当前在第 1 页时）：画标题。
        // ⚠️ 标题必须用槽位自己的章（slidePrevTitle），不能用
        // buildChapterHeading() —— 那读的是 state.chapterTitle。
        Column() {
          Text(this.slidePrevTitle)
            .fontSize(this.state.settings.fontSize + AppTheme.SIZE_STEP)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme().text)
            .fontFamily(ReaderSettings.resolveFontFamily(this.state.settings.fontFamily))
            .letterSpacing(AppTheme.TRACK_CHAPTER)
            .lineHeight(this.headingLineHeight())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ top: AppTheme.GAP_S, bottom: AppTheme.GAP_M })
        }
        .width('100%')
        .padding({
          left: this.state.settings.pageMargin,
          right: this.state.settings.pageMargin
        })
      }
      Text(this.slidePrevText)
        .fontSize(this.state.settings.fontSize)
        .fontColor(this.theme().text)
        .fontFamily(ReaderSettings.resolveFontFamily(this.state.settings.fontFamily))
        .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
        .letterSpacing(this.state.settings.letterSpacing)
        .textIndent(0)
        .width('100%')
        .padding({ left: this.state.settings.pageMargin, right: this.state.settings.pageMargin })
        .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildSlideNextSlot() {
    Column() {
      if (this.slideNextIsChapterHead) {
        // 下一章首页：画下一章的标题（不是当前章的！跨章时 state.chapterTitle
        // 还没更新，用它就会画出"当前章标题 + 下一章正文"的错配）
        Column() {
          Text(this.slideNextTitle)
            .fontSize(this.state.settings.fontSize + AppTheme.SIZE_STEP)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme().text)
            .fontFamily(ReaderSettings.resolveFontFamily(this.state.settings.fontFamily))
            .letterSpacing(AppTheme.TRACK_CHAPTER)
            .lineHeight(this.headingLineHeight())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ top: AppTheme.GAP_S, bottom: AppTheme.GAP_M })
        }
        .width('100%')
        .padding({
          left: this.state.settings.pageMargin,
          right: this.state.settings.pageMargin
        })
      }
      Text(this.slideNextText)
        .fontSize(this.state.settings.fontSize)
        .fontColor(this.theme().text)
        .fontFamily(ReaderSettings.resolveFontFamily(this.state.settings.fontFamily))
        .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
        .letterSpacing(this.state.settings.letterSpacing)
        .textIndent(0)
        .width('100%')
        .padding({ left: this.state.settings.pageMargin, right: this.state.settings.pageMargin })
        .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 说明见 docs/阅读页实现说明.md「@Builder」
  @Builder
  buildPagedPage() {
      if (this.state.pageIndex === 0) {
        // 说明见 docs/阅读页实现说明.md「Column() {」
        Column() {
          ReaderChapterHeading({
            text: this.headingText(),
            theme: this.theme(),
            settings: this.state.settings,
            lineHeight: this.headingLineHeight()
          })
        }
        .width('100%')
        .padding({
          left: this.state.settings.pageMargin,
          right: this.state.settings.pageMargin
        })
      }
      // 翻页与呼出菜单由上层 buildPageControls 处理
      // 说明见 docs/阅读页实现说明.md「Text('', { controller: this.textController }) {」
      Text('', { controller: this.textController }) {
        ForEach(this.buildTextRuns(), (run: TextRun) => {
          // 说明见 docs/阅读页实现说明.md「if (run.highlighted) {」
          if (run.highlighted) {
            Span(run.text)
              .textBackgroundStyle(AppTheme.highlightSpanStyle())
          } else {
            Span(run.text)
          }
        }, (run: TextRun, index: number) => `${index}_${run.highlighted}_${run.text.length}`)
      }
        .fontSize(this.state.settings.fontSize)
        .fontColor(this.theme().text)
        // 字体与分页测量同源（见 ReaderSettings.resolveFontFamily）
        .fontFamily(ReaderSettings.resolveFontFamily(this.state.settings.fontFamily))
        .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
        .letterSpacing(this.state.settings.letterSpacing)
        // 说明见 docs/阅读页实现说明.md「.textIndent(0)」
        .textIndent(0)
        .width('100%')
        // 允许长按选中并复制（配合下面的自定义菜单加"书签"）
        .copyOption(CopyOptions.InApp)
        // 长按选中后的菜单：在系统"复制"旁边加上"书签"
        .editMenuOptions(this.buildTextEditMenu())
        // 选区端点：如实回填当前选区，取消时压成 (0,0)（见字段说明）
        .selection(this.selStart, this.selEnd)
        // 跟踪"是否有选中"：有选中时第一次点击只取消选择（见 handleReaderTap）
        .onTextSelectionChange((start: number, end: number) => {
          this.hasSelection = end > start;
          this.selStart = start;
          this.selEnd = end;
        })
        // 左右页边距：与分页里减掉的 `pageMargin * 2` 对应，两边必须同一个值
        .padding({ left: this.state.settings.pageMargin, right: this.state.settings.pageMargin })
        .align(Alignment.TopStart)
        // 说明见 docs/阅读页实现说明.md「.onAreaChange((oldArea: Area, newArea: Area) => {」
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.onPagedTextAreaChange(newArea);
        })
  }

  // 说明见 docs/阅读页实现说明.md「private measureWidth(): number {」
  private measureWidth(): number {
    return Math.max(1, this.contentWidth - this.state.settings.pageMargin * 2);
  }

  // 说明见 docs/阅读页实现说明.md「private onPagedTextAreaChange(area: Area): void {」
  private onPagedTextAreaChange(area: Area): void {
    const height: number = Number(area.height);
    const text: string = this.state.renderedText;
    const lineHeight: number = Math.max(1,
      this.state.settings.fontSize * this.state.settings.lineHeight);
    const measuredLines: number = height / lineHeight;

    // 说明见 docs/阅读页实现说明.md「let measureCheck: string = '未注入';」
    let measureCheck: string = '未注入';
    if (this.vm.hasMeasureFn()) {
      const measured: number = this.vm.measureHeight(text, this.measureWidth());
      const diff: number = measured - height;
      measureCheck = `测量高=${measured.toFixed(1)} 差=${diff.toFixed(1)}`
        + `(${height > 0 ? ((diff / height) * 100).toFixed(1) : '0'}%)`;
    }

    // 数换行与空行：判断"物理行 vs 自然段"的关键证据
    let nlCount: number = 0;
    let blankCount: number = 0;
    for (let i = 0; i < text.length; i++) {
      if (text.charAt(i) !== '\n') {
        continue;
      }
      nlCount++;
      const next: number = i + 1;
      if (next < text.length && text.charAt(next) === '\n') {
        blankCount++;
      }
    }

    // 说明见 docs/阅读页实现说明.md「const heads: string[] = [];」
    const heads: string[] = [];
    let cursor: number = 0;
    let lineNo: number = 0;
    while (cursor <= text.length && lineNo < 6) {
      const nl: number = text.indexOf('\n', cursor);
      const lineEnd: number = nl < 0 ? text.length : nl;
      const line: string = text.substring(cursor, lineEnd);
      const code: string = line.length > 0 ? line.charCodeAt(0).toString(16) : '-';
      heads.push(`#${lineNo}:0x${code}(字${line.length})`);
      lineNo++;
      if (nl < 0) {
        break;
      }
      cursor = nl + 1;
    }

    Logger.info(LogTag.PAGINATION,
      `分页正文实测: 实高=${height.toFixed(1)} 行高=${lineHeight.toFixed(1)}`
        + ` 实测行数=${measuredLines.toFixed(1)}`
        + ` | 容器可用=${this.pageAreaHeight.toFixed(1)}`
        + ` 标题占位=${this.headingHeight().toFixed(1)}`
        + ` 本页字数=${text.length} 换行数=${nlCount} 空行段数=${blankCount}`
        + ` | 测量自检 ${measureCheck}`
        + ` | 行首码点 ${heads.join(' ')}`);
  }

  // 说明见 docs/阅读页实现说明.md「private onReaderScroll(): void {」
  private onReaderScroll(): void {
    // 说明见 docs/阅读页实现说明.md「if (this.isScrollRestoreBlocking()) {」
    if (this.isScrollRestoreBlocking()) {
      return;
    }
    // 绝对偏移：与章末判断同源，唯一可信来源
    const absoluteY: number = this.scroller.currentOffset().yOffset;
    this.handleContinuousScroll(absoluteY);

    // 章内偏移上报：只有当视口顶部在**当前章块**内时才按滚动量换算；
    // 落在相邻章块时偏移属于别的坐标系，交给 handleContinuousScroll 的
    // 可见章上报（reportVisibleChapter）处理。
    const currentTop: number = this.sectionTop(this.state.chapterIndex);
    const lineHeight: number = Math.max(1,
      this.state.settings.fontSize * this.state.settings.lineHeight);
    const charsPerLine: number = this.charsPerLineEstimate();
    if (absoluteY >= currentTop) {
      const withinY: number = absoluteY - currentTop;
      const lines: number = Math.floor(withinY / lineHeight);
      this.vm.reportScrollOffset(lines * charsPerLine);
    }
  }

  // 说明见 docs/阅读页实现说明.md「private handleContinuousScroll(absoluteY: number): void {」
  private handleContinuousScroll(absoluteY: number): void {
    // 程序化滚动冷却期内不检测跨章：恢复位置/跳章的滚动不是用户跨章
    if (Date.now() < this.autoContinueBlockedUntil) {
      return;
    }
    const target: number = this.chapterAtViewportTop(absoluteY);
    if (target < 0 || target === this.visibleChapterIndex) {
      return;
    }
    const previous: number = this.visibleChapterIndex;
    this.visibleChapterIndex = target;
    // 展示值即时跟随（章节名/百分比），不触发任何加载
    this.vm.reportVisibleChapter(target);
    if (previous >= 0 && previous !== target) {
      // 防抖晋升：滚停 250ms 后仍停在相邻章，才真正换当前章
      if (this.promoteTimerId >= 0) {
        clearTimeout(this.promoteTimerId);
      }
      this.promoteTimerId = setTimeout(() => {
        this.promoteTimerId = -1;
        this.promoteToVisibleChapter().catch((e: Object) => {
          Logger.error(LogTag.READ, `晋升可见章失败: ${Logger.errText(e)}`);
        });
      }, AppConstants.SCROLL_PROMOTE_DEBOUNCE_MS);
    }
  }

  // 说明见 docs/阅读页实现说明.md「private async promoteToVisibleChapter(): Promise<void> {」
  private async promoteToVisibleChapter(): Promise<void> {
    const target: number = this.visibleChapterIndex;
    if (target < 0 || target === this.state.chapterIndex) {
      return;
    }
    const prevY: number = this.scroller.currentOffset().yOffset;
    const preTop: number = this.sectionTop(target);
    const switched: boolean = await this.vm.promoteScrollWindow(target);
    if (!switched) {
      return;
    }
    this.visibleChapterIndex = target;
    // 说明见 docs/阅读页实现说明.md「const newTop: number = this.sectionTop(target);」
    const newTop: number = this.sectionTop(target);
    this.armAutoContinueCooldown();
    this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, prevY - preTop + newTop) });
  }

  private chapterAtViewportTop(y: number): number {
    const sections: ScrollSection[] = this.state.scrollSections;
    if (sections.length === 0) {
      return -1;
    }
    let acc: number = 0;
    for (const section of sections) {
      const h: number = this.sectionHeights.get(section.chapterIndex) ?? 0;
      // 高度未量出的块按"落在其中"处理（首帧），
      // 否则首帧会全部判到第一块
      if (y < acc + (h > 0 ? h : 1)) {
        return section.chapterIndex;
      }
      acc += h;
      if (h <= 0) {
        // 没量过高度的块给一个保守的屏高估计，避免累计全 0
        acc += this.viewportHeight;
      }
    }
    return sections[sections.length - 1].chapterIndex;
  }

  private sectionTop(chapterIndex: number): number {
    let acc: number = 0;
    for (const section of this.state.scrollSections) {
      if (section.chapterIndex === chapterIndex) {
        return acc;
      }
      const h: number = this.sectionHeights.get(section.chapterIndex) ?? 0;
      acc += h > 0 ? h : this.viewportHeight;
    }
    return acc;
  }

  private recordSectionHeight(chapterIndex: number, height: number): void {
    if (height > 0) {
      this.sectionHeights.set(chapterIndex, height);
    }
  }

  // 说明见 docs/阅读页实现说明.md「private charsPerLineEstimate(): number {」
  private charsPerLineEstimate(): number {
    return Math.max(1, Math.floor(this.contentWidth / Math.max(1, this.state.settings.fontSize)));
  }

  private onPageAreaChange(area: Area): void {
    const width: number = Number(area.width);
    const height: number = Number(area.height);
    if (width <= 0 || height <= 0) {
      return;
    }
    // 与 Scroll 的实测高度对照打日志：两者应当接近（差一个标题高度）。
    // "每页字多字少/上下留白"这类问题几乎都出在这里，有日志就不用反复猜。
    Logger.info(LogTag.READ,
      `阅读区实测: w=${width.toFixed(1)} h=${height.toFixed(1)}`
        + ` | Scroll 视口=${this.viewportHeight.toFixed(1)}`);
    const changed: boolean = Math.abs(width - this.contentWidth) > 1
      || Math.abs(height - this.pageAreaHeight) > 1;
    // ===== 诊断日志（定位"跨章闪一下"，问题解决后移除）=====
    if (changed) {
      Logger.info('SlideDiag', `[A0] 阅读区尺寸变化 w=${width.toFixed(1)} h=${height.toFixed(1)}`
        + ` (旧 ${this.contentWidth.toFixed(1)}x${this.pageAreaHeight.toFixed(1)})`
        + ` 章=${this.state.chapterIndex} t=${Date.now() % 100000}`);
    }
    this.contentWidth = width;
    this.pageAreaHeight = height;
    if (changed) {
      // 尺寸变化（旋转屏幕/改字号）需要重新分页
      this.tryPaginate();
    }
    // 说明见 docs/阅读页实现说明.md「this.applyPendingScrollRestore();」
    this.applyPendingScrollRestore();
  }

  private onScrollContentChange(area: Area): void {
    const height: number = Number(area.height);
    if (height > 0) {
      this.scrollContentHeight = height;
    }
    // 说明见 docs/阅读页实现说明.md「this.applyPendingScrollRestore();」
    this.applyPendingScrollRestore();
  }

  // 说明见 docs/阅读页实现说明.md「private resetScrollAfterChapterChange(): void {」
  private resetScrollAfterChapterChange(): void {
    if (this.state.settings.pageMode !== 'scroll') {
      return;
    }
    this.scrollRestoreOffset = -1;
    this.scrollRestoreRequestedAt = 0;
    this.visibleChapterIndex = this.state.chapterIndex;
    this.armAutoContinueCooldown();
    // 滚到**当前章块的起点**（窗口含上一章时不是 0）
    const targetTop: number = this.sectionTop(this.state.chapterIndex);
    this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, targetTop) });
  }

  // 说明见 docs/阅读页实现说明.md「private armAutoContinueCooldown(): void {」
  private armAutoContinueCooldown(): void {
    this.autoContinueBlockedUntil = Date.now() + AppConstants.AUTO_CONTINUE_COOLDOWN_MS;
  }

  // 说明见 docs/阅读页实现说明.md「private requestScrollRestore(offset: number): void {」
  private requestScrollRestore(offset: number): void {
    this.scrollRestoreOffset = Math.max(0, offset);
    this.scrollRestoreRequestedAt = Date.now();
  }

  // 说明见 docs/阅读页实现说明.md「private isScrollRestoreBlocking(): boolean {」
  private isScrollRestoreBlocking(): boolean {
    if (this.scrollRestoreOffset < 0) {
      return false;
    }
    const waited: number = Date.now() - this.scrollRestoreRequestedAt;
    if (waited > AppConstants.SCROLL_RESTORE_GIVEUP_MS) {
      Logger.warn(LogTag.READ,
        `滚动位置恢复超时（等待 ${waited}ms），放弃并恢复进度上报`);
      this.scrollRestoreOffset = -1;
      this.scrollRestoreRequestedAt = 0;
      return false;
    }
    return true;
  }

  // 说明见 docs/阅读页实现说明.md「private restoreScrollToCurrentOffset(): void {」
  private restoreScrollToCurrentOffset(): void {
    if (this.state.settings.pageMode !== 'scroll') {
      return;
    }
    // 重排（改字号/行距/边距/刷新）会改变每章块的高度 ——
    // 旧的实测高度全部作废，不清的话"视口落在哪章"会按旧高度算错
    this.sectionHeights.clear();
    this.requestScrollRestore(this.state.offset);
    this.scheduleScrollRestore();
  }

  // 说明见 docs/阅读页实现说明.md「private scheduleScrollRestore(): void {」
  private scheduleScrollRestore(): void {
    if (this.scrollRestoreOffset < 0) {
      return;
    }
    setTimeout(() => {
      this.applyPendingScrollRestore();
    }, AppConstants.READER_SCROLL_RESTORE_DELAY_MS);
  }

  // 说明见 docs/阅读页实现说明.md「private applyPendingScrollRestore(): void {」
  private applyPendingScrollRestore(): void {
    if (this.scrollRestoreOffset < 0
      || this.state.settings.pageMode !== 'scroll'
      || this.state.loading
      || this.contentWidth <= 0
      || this.viewportHeight <= 0
      || this.scrollContentHeight <= 0) {
      return;
    }
    const offset: number = this.scrollRestoreOffset;
    // 取走即清空：滚动是"一次性"动作，不清就会在每次高度变化时把用户拽回去
    this.scrollRestoreOffset = -1;
    this.scrollRestoreRequestedAt = 0;

    const lineHeight: number = Math.max(1,
      this.state.settings.fontSize * this.state.settings.lineHeight);
    const charsPerLine: number = this.charsPerLineEstimate();
    const lines: number = Math.round(offset / charsPerLine);
    // 说明见 docs/阅读页实现说明.md「const sectionTop: number = this.sectionTop(this.state.chapterIndex);」
    const sectionTop: number = this.sectionTop(this.state.chapterIndex);
    if (lines <= 0 && sectionTop <= 0) {
      // 章首且无上一章：本来就在顶部，不需要滚（也避免触发一次无意义的滚动回调）
      return;
    }
    const targetY: number = sectionTop + lines * lineHeight;
    // 说明见 docs/阅读页实现说明.md「this.armAutoContinueCooldown();」
    this.armAutoContinueCooldown();
    this.scroller.scrollTo({ xOffset: 0, yOffset: targetY });
    Logger.info(LogTag.READ,
      `滚动恢复位置: 偏移=${offset} → 行=${lines} → y=${targetY.toFixed(1)}`);
  }

  private goBack(): void {
    this.vm.close().then(() => {
      this.vm.dispose();
      this.back();
    }).catch(() => {
      this.vm.dispose();
      this.back();
    });
  }

  private back(): void {
    this.getUIContext().getRouter().back();
  }
}
