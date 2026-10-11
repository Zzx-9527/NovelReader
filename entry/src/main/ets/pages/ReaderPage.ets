import { BusinessError } from '@kit.BasicServicesKit';
import { ReaderState } from '../viewmodels/ReaderState';
import { ReaderViewModel } from '../viewmodels/ReaderViewModel';
import { RouteParam } from '../model/RouteParam';
import { AppColor, AppTheme, ReaderTheme } from '../common/theme/AppTheme';
import { Logger } from '../common/utils/Logger';
import { AppConstants, LogTag } from '../common/constants/AppConstants';
import { LoadingView } from '../views/common/LoadingView';
import { ErrorView } from '../views/common/ErrorView';
import { ReaderTopBar } from '../views/reader/ReaderTopBar';
import { ReaderBottomBar } from '../views/reader/ReaderBottomBar';
import { TocDrawer } from '../views/reader/TocDrawer';

/**
 * 阅读页（全屏，不显示底部 Tab）。
 *
 * 单击分区：左 1/3 上一页、右 1/3 下一页、中间呼出/隐藏菜单。
 */
@Entry
@Component
struct ReaderPage {
  @State state: ReaderState = new ReaderState();
  private vm: ReaderViewModel = new ReaderViewModel();
  /**
   * 阅读区高度（第 1 层那个 Column），分页用。
   *
   * ⚠️ 量的必须是这个**高度恒定**的容器，而不是正文 Text 本身：
   * 分页模式下正文 Text 在本章第一页要给章节标题让位（高度少一截），
   * 若量它，翻到第二页尺寸又变回去 ⇒ 触发重新分页 ⇒ 页码归零 ⇒ 回到第一页 ⇒
   * **死循环**。恒定容器 + 把标题高度单独告诉分页服务，才是稳的。
   */
  private pageAreaHeight: number = 0;
  private contentWidth: number = 0;
  /**
   * scroll 模式：正文内容（章节标题 + 正文）的总高度。
   * 判断"这一章能不能滚""是否已滚到章末"用它。
   */
  private scrollContentHeight: number = 0;
  /**
   * 正文滚动容器。
   * 必须持有它才能拿到**绝对滚动偏移**（`currentOffset()`）——
   * `onScroll` 回调里的那个 offset 语义在不同 API 版本上并不一致，
   * 判断"是否滚到章末"这种事不能建立在它上面。
   */
  private scroller: Scroller = new Scroller();
  /** Scroll 自身高度（= 可视高度），与正文内容高度相减才能判断"能不能滚" */
  private viewportHeight: number = 0;
  /** 自动衔接的冷却截止时间戳，见 `AppConstants.AUTO_CONTINUE_COOLDOWN_MS` */
  private autoContinueBlockedUntil: number = 0;

  aboutToAppear(): void {
    this.state = this.vm.state;
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
      this.tryPaginate();
    }).catch((e: BusinessError) => {
      Logger.error(LogTag.READ, `打开阅读页失败: ${e.message}`);
    });
  }

  aboutToDisappear(): void {
    // 必须释放：结算阅读时长 + 关闭文件句柄
    this.vm.close().then(() => {
      this.vm.dispose();
    }).catch(() => {
      this.vm.dispose();
    });
  }

  /** 拿到正文区尺寸后才可能算分页；尺寸变化（旋转屏幕）也要重算 */
  private tryPaginate(): void {
    if (this.pageAreaHeight <= 0 || this.contentWidth <= 0) {
      return;
    }
    this.vm.setContentSize(this.contentWidth, this.pageAreaHeight, this.headingHeight());
    if (this.state.settings.pageMode !== 'scroll') {
      this.vm.loadChapter(this.state.chapterIndex);
    }
  }

  private theme(): ReaderTheme {
    return ReaderTheme.of(this.state.settings.theme);
  }

  build() {
    Stack() {
      // 第 1 层：正文（最底）。章节标题是正文的第一行，见 buildReaderBody
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
      .height('100%')
      .backgroundColor(this.theme().bg)
      // 量出分页可用的**恒定**高度（见 pageAreaHeight 的说明）
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.onPageAreaChange(newArea);
      })

      // 第 2 层：翻页层（点击分区 + 左右滑动）。
      // ⚠️ 两条约束，缺一不可：
      //
      //  1. 只在"菜单隐藏时"存在 —— 否则它会覆盖在顶栏/底栏之上把点击截走，
      //     导致菜单弹出后无法收回（点中间等于又切换一次）。
      //
      //  2. **滚动模式绝不能有这一层** —— 这三个 Column 都绑了 onClick，
      //     按 ArkUI 的触摸测试规则（HitTestMode.Default：自身响应 + 阻塞兄弟节点），
      //     它们会把拖拽事件整个吃掉，下层 `Scroll` 永远收不到滑动。
      //     实测表现就是"阅读页划不动、只能点"。
      //     滚动模式下的点击交给 Scroll 自己接管（见 buildReaderBody）。
      if (!this.state.menuVisible && this.state.error.length === 0 && !this.state.loading
        && this.state.settings.pageMode !== 'scroll') {
        this.buildPageControls()
      }

      // 第 3 层：顶栏 / 底栏（只在菜单显示时出现，且位于翻页层之上）
      if (this.state.menuVisible && this.state.error.length === 0) {
        Column() {
          ReaderTopBar({
            title: this.state.chapterTitle,
            theme: this.theme(),
            onBack: () => {
              this.goBack();
            },
            onMenu: () => {
              this.vm.setTocVisible(true);
            }
          })
          // 菜单显示时，点中间空白处收回菜单。
          // 分页模式下翻页层此时**不存在**（两块区域互斥渲染），没有这个点击点，
          // 用户就只能靠"返回/目录"关菜单 —— 这是"菜单弹出来收不回去"的另一半。
          // 用 hideMenu() 而不是 toggleMenu()：收起是幂等的，
          // 不存在"连点两下又打开了"的抖动。
          Blank()
            .onClick(() => {
              this.vm.hideMenu();
            })
          ReaderBottomBar({
            theme: this.theme(),
            baseFontSize: this.state.settings.fontSize,
            percent: this.state.percent,
            chapterTitle: this.state.chapterTitle,
            pageText: this.state.pageText,
            hasPrev: this.state.hasPrev,
            hasNext: this.state.hasNext,
            onJump: (percent: number) => {
              this.vm.jumpToChapterByPercent(percent);
            },
            // 上一章回到"上一章的最后一页"（switchChapter 内部处理），
            // 符合"往回翻"的直觉
            onPrevChapter: () => {
              this.vm.prevChapter();
            },
            onNextChapter: () => {
              this.vm.nextChapter();
            }
          })
        }
        .width('100%')
        .height('100%')
      }

      // 第 4 层：目录抽屉（最顶，带遮罩）
      if (this.state.tocVisible) {
        Row() {
          TocDrawer({
            chapters: this.state.chapters,
            currentIndex: this.state.chapterIndex,
            theme: this.theme(),
            onSelect: (chapterIndex: number) => {
              this.vm.setTocVisible(false);
              this.vm.jumpToChapter(chapterIndex);
            },
            onClose: () => {
              this.vm.setTocVisible(false);
            }
          })
          Blank()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.mask)
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 分页模式的翻页层：左 1/3 上一页、中 1/3 呼出菜单、右 1/3 下一页，
   * 左右滑动同样翻页（很多人第一反应就是滑，不该只有点击这一条路）。
   */
  @Builder
  buildPageControls() {
    Row() {
      Column()
        .width('33%')
        .height('100%')
        .onClick(() => {
          this.vm.prevPage();
        })

      Column()
        .width('34%')
        .height('100%')
        .onClick(() => {
          this.vm.toggleMenu();
        })

      Column()
        .width('33%')
        .height('100%')
        .onClick(() => {
          this.vm.nextPage();
        })
    }
    .width('100%')
    .height('100%')
    // 手势挂在**整层**而不是三个分区上：一次滑动可能跨过两个分区，
    // 挂在父节点才能拿到完整位移。
    //
    // 用 PanGesture 的 offsetX 而不是 SwipeGesture 的 angle：
    // 位移的正负没有歧义（左滑为负），不必去记 angle 的角度约定。
    // 只认水平方向 —— 竖直滑动不属于翻页语义，让它落空即可。
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionEnd((event: GestureEvent) => {
          const dx: number = event.offsetX;
          if (dx <= -AppConstants.PAGE_SWIPE_MIN_DISTANCE) {
            this.vm.nextPage();
          } else if (dx >= AppConstants.PAGE_SWIPE_MIN_DISTANCE) {
            this.vm.prevPage();
          }
        })
    )
  }

  // ------------------------------------------------------------ 正文

  /**
   * 页眉文案 = 当前章节标题。
   *
   * 直接用手里的 `chapter.title`，**不再拼一个 App 自己的序号**：
   * `ChapterParser` 只把"匹配章节标记的行"收作 title（`^第 x 章/节/回`、
   * `CHAPTER n`、`序章/楔子/番外`…），所以标题本身就带序号 ——
   * 再拼一次就成了"第 64 章 · 第一章 玄鉴"这种重复。
   * 只有标题为空时才退回序号，取法与目录抽屉保持一致。
   */
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

  /** 章节标题的行高（必须与 buildChapterHeading 里设置的一致） */
  private headingLineHeight(): number {
    return (this.state.settings.fontSize + AppTheme.SIZE_STEP) * this.state.settings.lineHeight;
  }

  /**
   * 章节标题占用的总高度；本章没有标题则为 0。
   *
   * 分页模式必须把它交给分页服务：**首页的可用高度比其它页少这一截**，
   * 不告诉它就会多算一行，首页最后一行被裁掉（而且裁掉的是正文，用户看不出原因）。
   */
  private headingHeight(): number {
    if (this.headingText().length === 0) {
      return 0;
    }
    return this.headingLineHeight() + AppTheme.GAP_S + AppTheme.GAP_M;
  }

  /**
   * 章节标题：它是**正文的第一行**，不是常驻页眉 —— 读过就跟着滚走。
   *
   * 字号 = 正文 + `AppTheme.SIZE_STEP`，加粗：标题必须比正文更重，
   * 否则和正文混在一起就不成其为标题。用相对量而非固定字号，
   * 是为了用户把正文调大时层级不会反过来。
   *
   * 左右**不留内边距**：要和正文的左边距对齐，看起来才是"正文里的一行"，
   * 而不是浮在正文之外的装饰。与正文的区别只有字号、字重和下面垫的那点空隙。
   *
   * 单行省略：章节名偶尔很长（"第 3 章 他在雨里站了整整一夜"），
   * 换行会挤掉正文，截断更划算 —— 完整标题在目录里能看全。
   */
  @Builder
  buildChapterHeading() {
    if (this.headingText().length > 0) {
      Text(this.headingText())
        .fontSize(this.state.settings.fontSize + AppTheme.SIZE_STEP)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme().text)
        // 显式给行高：高度要可预测，分页按 headingHeight() 扣它
        .lineHeight(this.headingLineHeight())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ top: AppTheme.GAP_S, bottom: AppTheme.GAP_M })
    }
  }

  @Builder
  buildReaderBody() {
    if (this.state.settings.pageMode === 'scroll') {
      // 滚动模式：标题 + 整章正文在一个可滚动容器里，标题跟着滚走
      Scroll(this.scroller) {
        Column() {
          this.buildChapterHeading()
          Text(this.state.renderedText)
            .fontSize(this.state.settings.fontSize)
            .fontColor(this.theme().text)
            .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
            .letterSpacing(this.state.settings.letterSpacing)
            .textIndent(this.state.settings.firstLineIndent * this.state.settings.fontSize)
            .width('100%')
        }
        .width('100%')
        // 量的是"标题 + 正文"的**内容总高度**：判断是否滚到章末时
        // 标题占的高度也算在内，否则会提前一行触发自动衔接
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
      // 量出可视高度：判断"这一章能不能滚""是否已滚到章末"都要它
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.viewportHeight = Number(newArea.height);
      })
      // 单击切菜单挂在 Scroll 上而不是 Text 上，两个原因：
      //  1. Scroll 铺满整屏，短章节时正文下方的空白区也能点；
      //  2. 父子同时绑 onClick 会变成两个 TapGesture 竞争，
      //     万一都触发就是"切换两次 = 菜单根本没开"。
      .onClick(() => {
        this.vm.toggleMenu();
      })
      .onScroll((scrollOffset: number) => {
        this.onReaderScroll(scrollOffset);
      })
    } else {
      // 分页模式：标题只出现在本章第一页。首页让位的那一截高度
      // 已通过 setContentSize(..., headingHeight()) 交给分页服务扣除，
      // 所以这里直接渲染不会把首页最后一行挤掉。
      if (this.state.pageIndex === 0) {
        this.buildChapterHeading()
      }
      // 翻页与呼出菜单由上层 buildPageControls 处理
      Text(this.state.renderedText)
        .fontSize(this.state.settings.fontSize)
        .fontColor(this.theme().text)
        .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
        .letterSpacing(this.state.settings.letterSpacing)
        .textIndent(this.state.settings.firstLineIndent * this.state.settings.fontSize)
        .width('100%')
        // 占满"减去标题"的剩余高度（layoutWeight 取的是剩余空间，不是父容器的 100%）
        .layoutWeight(1)
    }
  }

  /**
   * 滚动模式的每帧回调：上报阅读进度 + 判断是否该无缝衔接下一章。
   */
  private onReaderScroll(scrollOffset: number): void {
    // 用滚动量估算当前字符偏移：行高与每行字数都由字号推出
    const lineHeight: number = Math.max(1,
      this.state.settings.fontSize * this.state.settings.lineHeight);
    const charsPerLine: number = Math.max(1,
      Math.floor(this.contentWidth / Math.max(1, this.state.settings.fontSize)));
    const lines: number = Math.floor(scrollOffset / lineHeight);
    this.vm.reportScrollOffset(lines * charsPerLine);

    if (this.shouldContinueToNextChapter()) {
      // 先上锁再切章：切章过程中还会到达若干次滚动回调，
      // 此时"到底了没"用的仍是旧内容的高度，不锁就会连跳好几章
      this.autoContinueBlockedUntil = Date.now() + AppConstants.AUTO_CONTINUE_COOLDOWN_MS;
      // 接住 Promise：不接的话衔接失败会被完全静默吞掉（设计文档第 26 条）
      this.continueToNextChapter().catch((e: Object) => {
        Logger.error(LogTag.READ, `章末自动衔接失败: ${Logger.errText(e)}`);
      });
    }
  }

  /** 是否已滚到章末，该自动衔接下一章了 */
  private shouldContinueToNextChapter(): boolean {
    if (Date.now() < this.autoContinueBlockedUntil
      || this.state.loading || !this.state.hasNext) {
      return false;
    }
    // ⚠️ 先判断"这一章到底能不能滚"：
    // 章节短到一屏放得下时 `scrollContentHeight <= viewportHeight`，
    // 滚动条本来就在底部 —— 少了这一句就会"短章无限自动连跳"直到全书末尾。
    if (this.viewportHeight <= 0 || this.scrollContentHeight <= this.viewportHeight + 1) {
      return false;
    }
    const y: number = this.scroller.currentOffset().yOffset;
    return y + this.viewportHeight >= this.scrollContentHeight - 2;
  }

  /**
   * 无缝衔接：静默加载下一章，并把正文滚回顶部。
   *
   * 滚回顶部这步不能省：内容换了但滚动位置还停在上一章的 max 处，
   * 新章会直接从末尾开始显示 —— 那就不是"衔接"而是"跳章"了。
   */
  private async continueToNextChapter(): Promise<void> {
    const switched: boolean = await this.vm.continueToNextChapter();
    if (switched) {
      this.scroller.scrollEdge(Edge.Top);
    }
  }

  /** 阅读区（第 1 层 Column）尺寸变化 → 重算分页 */
  private onPageAreaChange(area: Area): void {
    const width: number = Number(area.width);
    const height: number = Number(area.height);
    if (width <= 0 || height <= 0) {
      return;
    }
    const changed: boolean = Math.abs(width - this.contentWidth) > 1
      || Math.abs(height - this.pageAreaHeight) > 1;
    this.contentWidth = width;
    this.pageAreaHeight = height;
    if (changed) {
      // 尺寸变化（旋转屏幕/改字号）需要重新分页
      this.tryPaginate();
    }
  }

  /** scroll 模式：正文内容总高度变化（含章节标题） */
  private onScrollContentChange(area: Area): void {
    const height: number = Number(area.height);
    if (height > 0) {
      this.scrollContentHeight = height;
    }
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
