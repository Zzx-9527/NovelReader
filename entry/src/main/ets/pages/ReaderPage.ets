import { BusinessError } from '@kit.BasicServicesKit';
import { ReaderState } from '../viewmodels/ReaderState';
import { ReaderViewModel } from '../viewmodels/ReaderViewModel';
import { RouteParam } from '../model/RouteParam';
import { AppColor, ReaderTheme } from '../common/theme/AppTheme';
import { Logger } from '../common/utils/Logger';
import { LogTag } from '../common/constants/AppConstants';
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
  /** 正文区实际高度，用于分页（宽度取容器宽度） */
  @State contentHeight: number = 0;
  private contentWidth: number = 0;

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
    if (this.contentHeight <= 0 || this.contentWidth <= 0) {
      return;
    }
    this.vm.setContentSize(this.contentWidth, this.contentHeight);
    if (this.state.settings.pageMode !== 'scroll') {
      this.vm.loadChapter(this.state.chapterIndex);
    }
  }

  private theme(): ReaderTheme {
    return ReaderTheme.of(this.state.settings.theme);
  }

  build() {
    Stack() {
      // 第 1 层：正文（最底）
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

      // 第 2 层：点击分区。
      // ⚠️ 必须只在"菜单隐藏时"存在 —— 否则它会覆盖在顶栏/底栏之上把点击截走，
      // 导致菜单弹出后无法收回（点中间等于又切换一次）。
      if (!this.state.menuVisible && this.state.error.length === 0 && !this.state.loading) {
        this.buildTapZones()
      }

      // 第 3 层：顶栏 / 底栏（只在菜单显示时出现，且位于点击分区之上）
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
          Blank()
          ReaderBottomBar({
            theme: this.theme(),
            percent: this.state.percent,
            chapterTitle: this.state.chapterTitle,
            pageText: this.state.pageText,
            onJump: (percent: number) => {
              this.vm.jumpToChapterByPercent(percent);
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

  /** 点击分区：左 1/3 上一页、中 1/3 呼出菜单、右 1/3 下一页 */
  @Builder
  buildTapZones() {
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
  }

  // ------------------------------------------------------------ 正文

  @Builder
  buildReaderBody() {
    if (this.state.settings.pageMode === 'scroll') {
      // 滚动模式：整章在一个可滚动容器里
      Scroll() {
        Text(this.state.renderedText)
          .fontSize(this.state.settings.fontSize)
          .fontColor(this.theme().text)
          .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
          .letterSpacing(this.state.settings.letterSpacing)
          .textIndent(this.state.settings.firstLineIndent * this.state.settings.fontSize)
          .width('100%')
          .onAreaChange((oldArea: Area, newArea: Area) => {
            this.onTextAreaChange(newArea);
          })
          .onClick(() => {
            this.vm.toggleMenu();
          })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .onScroll((scrollOffset: number) => {
        // 用滚动量估算当前字符偏移：行高与每行字数都由字号推出
        const lineHeight: number = Math.max(1,
          this.state.settings.fontSize * this.state.settings.lineHeight);
        const charsPerLine: number = Math.max(1,
          Math.floor(this.contentWidth / Math.max(1, this.state.settings.fontSize)));
        const lines: number = Math.floor(scrollOffset / lineHeight);
        this.vm.reportScrollOffset(lines * charsPerLine);
      })
    } else {
      // 分页模式：只渲染当前页；翻页与呼出菜单由上层 buildTapZones 处理
      Text(this.state.renderedText)
        .fontSize(this.state.settings.fontSize)
        .fontColor(this.theme().text)
        .lineHeight(this.state.settings.fontSize * this.state.settings.lineHeight)
        .letterSpacing(this.state.settings.letterSpacing)
        .textIndent(this.state.settings.firstLineIndent * this.state.settings.fontSize)
        .width('100%')
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.onTextAreaChange(newArea);
        })
    }
  }

  /** 量出正文可用区域，交给 ViewModel 分页 */
  private onTextAreaChange(area: Area): void {
    const width: number = Number(area.width);
    const height: number = Number(area.height);
    if (width <= 0 || height <= 0) {
      return;
    }
    const changed: boolean = Math.abs(width - this.contentWidth) > 1
      || Math.abs(height - this.contentHeight) > 1;
    this.contentWidth = width;
    this.contentHeight = height;
    this.vm.setContentSize(width, height);
    if (changed) {
      // 尺寸变化（旋转屏幕/改字号）需要重新分页
      this.tryPaginate();
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
