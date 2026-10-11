import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { ShelfState } from '../viewmodels/ShelfState';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { BookSort } from '../data/repository/BookRepository';
import { StorageBootstrap } from '../common/StorageBootstrap';
import { AppTheme } from '../common/theme/AppTheme';
import { LoadingView } from '../views/common/LoadingView';
import { EmptyView } from '../views/common/EmptyView';
import { ErrorView } from '../views/common/ErrorView';
import { BookGridItem } from '../views/bookshelf/BookGridItem';
import { BookListItem } from '../views/bookshelf/BookListItem';
import { ContinueReadingCard } from '../views/bookshelf/ContinueReadingCard';
import { RouteName, RouteParam } from '../model/RouteParam';

/**
 * 书架页。
 *
 * 分层约定：本页只调用 ViewModel，不 import 任何 Repository / database。
 *
 * 状态传递方式：`state` 是根页面持有的 `@Observed` 对象，本页用 `@State` 接收 ——
 * 这样"状态跟着页面生命周期走"，切换 Tab 不会丢滚动位置与分组选择；
 * ViewModel 由本页自建（它只依赖状态与 Repository，无额外状态）。
 */
@Component
export struct BookShelfPage {
  @State state: ShelfState = new ShelfState();
  private vm: BookShelfViewModel = new BookShelfViewModel();

  aboutToAppear(): void {
    this.vm.bind(this.state);
    StorageBootstrap.ensureReady().then(() => {
      this.vm.init();
    }).catch(() => {
      // 失败由页面错误态呈现
    });
  }

  aboutToDisappear(): void {
    this.vm.dispose();
  }

  build() {
    Column() {
      this.buildHeader()

      if (this.state.loading && this.state.books.length === 0) {
        LoadingView({ message: '正在加载书架…' })
      } else if (this.state.error.length > 0 && this.state.books.length === 0) {
        ErrorView({
          message: this.state.error,
          hint: '下拉重试，或检查存储权限',
          actionText: '重试',
          onRetry: () => {
            this.vm.clearError();
            this.vm.refresh();
          }
        })
      } else if (this.state.isEmpty) {
        EmptyView({
          title: '书架还是空的',
          hint: '导入一本本地 TXT 小说开始阅读。所有文件都保存在本机，不会上传。',
          actionText: '导入 TXT',
          onAction: () => {
            this.doImport();
          }
        })
      } else {
        this.buildBookList()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.BG_PAGE)
  }

  // ------------------------------------------------------------ 头部

  @Builder
  buildHeader() {
    Column({ space: AppTheme.GAP_M }) {
      Row({ space: AppTheme.GAP_S }) {
        Text('书架')
          .fontSize(AppTheme.FONT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.TEXT_PRIMARY)
          .layoutWeight(1)

        Text(this.state.gridMode ? '列表' : '网格')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.PRIMARY)
          .padding(8)
          .onClick(() => {
            this.vm.toggleGridMode();
          })

        Text('排序')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.PRIMARY)
          .padding(8)
          .onClick(() => {
            this.showSortMenu();
          })

        Button('导入')
          .fontSize(AppTheme.FONT_CAPTION)
          .height(32)
          .backgroundColor(AppTheme.PRIMARY)
          .enabled(!this.state.importing)
          .onClick(() => {
            this.doImport();
          })
      }
      .width('100%')

      if (this.state.importMessage.length > 0) {
        Text(this.state.importMessage)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.TEXT_SECONDARY)
          .width('100%')
      }

      if (this.state.continueBook !== null) {
        ContinueReadingCard({
          book: this.state.continueBook,
          onContinue: (book: Book) => {
            this.openReader(book);
          }
        })
      }

      this.buildGroupTabs()
    }
    .width('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })
  }

  @Builder
  buildGroupTabs() {
    Scroll() {
      Row({ space: AppTheme.GAP_S }) {
        this.groupChip('全部', -1)
        ForEach(this.state.groups, (group: BookGroup) => {
          this.groupChip(group.name, group.id)
        }, (group: BookGroup) => `${group.id}`)
      }
      .padding({ right: AppTheme.GAP_S })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  @Builder
  groupChip(label: string, groupId: number) {
    Text(label)
      .fontSize(AppTheme.FONT_CAPTION)
      .fontColor(this.state.selectedGroupId === groupId
        ? AppTheme.TEXT_ON_PRIMARY
        : AppTheme.TEXT_SECONDARY)
      .backgroundColor(this.state.selectedGroupId === groupId
        ? AppTheme.PRIMARY
        : AppTheme.BG_CARD)
      .borderRadius(14)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .onClick(() => {
        this.vm.selectGroup(groupId);
      })
  }

  // ------------------------------------------------------------ 书籍列表

  @Builder
  buildBookList() {
    if (this.state.gridMode) {
      Grid() {
        ForEach(this.state.books, (book: Book) => {
          GridItem() {
            BookGridItem({
              book: book,
              onTap: (b: Book) => {
                this.openReader(b);
              },
              onLongPress: (b: Book) => {
                this.showBookActions(b);
              }
            })
          }
        }, (book: Book) => `${book.id}`)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(AppTheme.GAP_M)
      .rowsGap(AppTheme.GAP_M)
      .padding({
        left: AppTheme.PAGE_PADDING,
        right: AppTheme.PAGE_PADDING,
        top: AppTheme.GAP_M,
        bottom: AppTheme.GAP_L
      })
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    } else {
      List({ space: AppTheme.GAP_S }) {
        ForEach(this.state.books, (book: Book) => {
          ListItem() {
            BookListItem({
              book: book,
              onTap: (b: Book) => {
                this.openReader(b);
              },
              onLongPress: (b: Book) => {
                this.showBookActions(b);
              }
            })
          }
        }, (book: Book) => `${book.id}`)
      }
      .padding({
        left: AppTheme.PAGE_PADDING,
        right: AppTheme.PAGE_PADDING,
        top: AppTheme.GAP_M,
        bottom: AppTheme.GAP_L
      })
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
  }

  // ------------------------------------------------------------ 交互

  private async doImport(): Promise<void> {
    const preparation = await this.vm.pickAndPrepare();
    if (preparation === null) {
      if (this.state.error.length > 0) {
        this.toast(this.state.error);
        this.vm.clearError();
      }
      return;
    }
    // 编码置信度低时提示用户（确认页在下一轮补，这里先提示后继续）
    if (preparation.result.lowConfidence) {
      this.toast(`编码识别为 ${preparation.encoding}，如正文乱码请稍后手动指定`);
    }
    const bookId: number = await this.vm.commitPendingImport();
    if (bookId > 0) {
      this.toast('导入完成');
    } else if (this.state.error.length > 0) {
      this.toast(this.state.error);
      this.vm.clearError();
    }
  }

  private showSortMenu(): void {
    promptAction.showActionMenu({
      title: '书架排序',
      buttons: [
        { text: '最近阅读', color: AppTheme.TEXT_PRIMARY },
        { text: '导入时间', color: AppTheme.TEXT_PRIMARY },
        { text: '书名', color: AppTheme.TEXT_PRIMARY }
      ]
    }).then((result: promptAction.ActionMenuSuccessResponse) => {
      if (result.index === 0) {
        this.vm.changeSort(BookSort.LAST_READ);
      } else if (result.index === 1) {
        this.vm.changeSort(BookSort.ADDED);
      } else if (result.index === 2) {
        this.vm.changeSort(BookSort.TITLE);
      }
    }).catch(() => {
      // 用户取消，不处理
    });
  }

  private showBookActions(book: Book): void {
    promptAction.showActionMenu({
      title: book.title,
      buttons: [
        { text: '开始阅读', color: AppTheme.PRIMARY },
        { text: '从书架移除', color: AppTheme.DANGER }
      ]
    }).then(async (result: promptAction.ActionMenuSuccessResponse) => {
      if (result.index === 0) {
        this.openReader(book);
      } else if (result.index === 1) {
        await this.vm.removeBook(book.id);
        this.toast('已移出书架');
      }
    }).catch(() => {
      // 用户取消
    });
  }

  private openReader(book: Book): void {
    const param: RouteParam = new RouteParam();
    param.bookId = book.id;
    param.from = RouteName.BOOK_SHELF;
    // 用 @Entry 页面 + router：ReaderPage 需登记在 resources/base/profile/main_pages.json。
    // 这样不依赖在非 @Entry 文件里 import 另一个 @Entry 页面（ArkTS 不允许）。
    router.pushUrl({ url: RouteName.READER_PAGE, params: param })
      .catch(() => {
        this.toast('打开阅读页失败');
      });
  }

  private toast(message: string): void {
    promptAction.showToast({ message: message, duration: 2000 });
  }
}
