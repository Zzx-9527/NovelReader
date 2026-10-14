// 仅用其**类型**（promptAction.Button）—— 调用一律走
// this.getUIContext().getPromptAction()，全局函数已废弃（见 §5.6 第 19 条）
import { promptAction } from '@kit.ArkUI';
import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { ShelfState } from '../viewmodels/ShelfState';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { BookSort } from '../data/repository/BookRepository';
import { StorageBootstrap } from '../common/StorageBootstrap';
import { AppColor, AppColorLiteral, AppTheme } from '../common/theme/AppTheme';
import { Encodings } from '../common/utils/EncodingDetector';
import { Logger } from '../common/utils/Logger';
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
 * ⚠️ **状态对象与 ViewModel 必须成对传入，且必须调用 `vm.bind(state)`。**
 *
 * 这不是可选的美化：`ShelfState` 是 `@Observed` + 本页 `@ObjectLink`，
 * 而 ViewModel 把数据写进 `vm.state`。若两者不是**同一个对象实例**，
 * 就会出现"数据早就加载好了，UI 却永远停在 loading"这类故障
 * （`ShelfState.loading` 初值为 true，没人把它改回 false）。
 *
 * 所以由根页面 `Index` 持有这一对实例并传进来：
 *  - 状态跟着根页面走 → 切 Tab 不丢滚动位置与分组选择；
 *  - ShelfRefreshRegistry 注册的也是同一个 vm → 刷新链路完整。
 */
@Component
export struct BookShelfPage {
  /**
   * 与根页面共享的 `@Observed` 状态。
   * `@ObjectLink` 而非 `@State`：后者接收参数时只做顶层赋值，
   * 观察不到对象**内部字段**（books/loading/error）的变化。
   */
  @ObjectLink state: ShelfState;
  /** 与根页面共享的 ViewModel；由 `Index` 构造并传入 */
  private vm!: BookShelfViewModel;

  aboutToAppear(): void {
    // 关键一步：让 ViewModel 与 UI 操作同一个状态对象。
    // 必须在 init() 之前 —— init() 会写 state.gridMode/sort。
    this.vm.bind(this.state);

    // 注册到根页面：onPageShow 只对 @Entry 页面触发，普通 @Component 指望不上，
    // 所以由根页面在"从阅读页返回 / 切回书架 Tab"时显式调用 refreshFromHost()。
    ShelfRefreshRegistry.current = this.vm;
    StorageBootstrap.ensureReady().then(() => {
      this.vm.init();
    }).catch((e: Object) => {
      this.state.error = `初始化失败：${Logger.errText(e)}`;
      this.state.loading = false;
    });
  }

  aboutToDisappear(): void {
    if (ShelfRefreshRegistry.current === this.vm) {
      ShelfRefreshRegistry.current = null;
    }
    this.vm.dispose();
  }

  /** 由根页面调用：重载书架数据 */
  refreshFromHost(): void {
    this.vm.reloadData();
  }

  build() {
    Column() {
      this.buildHeader()

      if (this.state.loading && this.state.books.length === 0) {
        LoadingView({ message: this.state.reparsing ? '正在重新解析…' : '正在加载书架…' })
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
    .backgroundColor(AppColor.bgPage)
  }

  // ------------------------------------------------------------ 头部

  @Builder
  buildHeader() {
    Column({ space: AppTheme.GAP_M }) {
      Row({ space: AppTheme.GAP_S }) {
        Text('书架')
          .fontSize(AppTheme.FONT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)

        // 两个文字操作：属于**小面积点缀**，保留主题色
        Text(this.state.gridMode ? '列表' : '网格')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
          .padding(8)
          .onClick(() => {
            this.vm.toggleGridMode();
          })

        Text('排序')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
          .padding(8)
          .onClick(() => {
            this.showSortMenu();
          })

        /**
         * 「导入」按钮：**中性填充**，不是点缀色。
         *
         * ⚠️ `fontColor` 必须显式设成 `onPrimary`：`Button` 默认字色是白色，
         * 深色模式下 `primary` 接近白色，不设就"白底白字"看不见。
         */
        Button('导入')
          .fontSize(AppTheme.FONT_CAPTION)
          .height(32)
          .backgroundColor(AppColor.primary)
          .fontColor(AppColor.onPrimary)
          .enabled(!this.state.importing)
          .onClick(() => {
            this.doImport();
          })
      }
      .width('100%')

      if (this.state.importMessage.length > 0) {
        Text(this.state.importMessage)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textSecondary)
          .width('100%')
      }

      if (this.state.reparseMessage.length > 0) {
        Text(this.state.reparseMessage)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
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
    /**
     * 选中的分组标签用**中性填充**（`primary` / `onPrimary`），不用点缀色。
     *
     * ⚠️ 它是**实心大色块**：一行里同时有多个标签，若选中那个用主题色，
     * 整条标签栏的视觉重量会全压到它身上，而分组只是个筛选条件、
     * 不值得抢走主视线。中性填充同样能表达"选中"，且不破坏黑白灰的基调。
     */
    Text(label)
      .fontSize(AppTheme.FONT_CAPTION)
      .fontColor(this.state.selectedGroupId === groupId
        ? AppColor.onPrimary
        : AppColor.textSecondary)
      .backgroundColor(this.state.selectedGroupId === groupId
        ? AppColor.primary
        : AppColor.bgCard)
      .borderRadius(AppTheme.CHIP_RADIUS)
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
    this.getUIContext().getPromptAction().showActionMenu({
      title: '书架排序',
      buttons: [
        { text: '最近阅读', color: AppColorLiteral.textPrimary },
        { text: '导入时间', color: AppColorLiteral.textPrimary },
        { text: '书名', color: AppColorLiteral.textPrimary }
      ]
    }).then((result) => {
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
    this.getUIContext().getPromptAction().showActionMenu({
      title: book.title,
      buttons: [
        { text: '开始阅读', color: AppColorLiteral.accent },
        { text: '换编码（正文乱码时用）', color: AppColorLiteral.textPrimary },
        { text: '从书架移除', color: AppColorLiteral.danger }
      ]
    }).then(async (result) => {
      if (result.index === 0) {
        this.openReader(book);
      } else if (result.index === 1) {
        await this.showEncodingPicker(book);
      } else if (result.index === 2) {
        await this.vm.removeBook(book.id);
        this.toast('已移出书架');
      }
    }).catch(() => {
      // 用户取消
    });
  }

  /**
   * 换编码重新解析。
   *
   * 正文乱码时的自救手段：自动探测不可能对每个 TXT 都准确，
   * 与其让用户重新导入，不如让他手动指定编码后重建章节。
   *
   * 注意：重新分章会因外键 CASCADE 删除该书书签/笔记，所以标题里先告知数量。
   */
  private async showEncodingPicker(book: Book): Promise<void> {
    const current: string = await this.vm.currentEncoding(book.id);
    const impacted: number = await this.vm.annotationsImpacted(book.id);

    const options: string[] = [
      Encodings.UTF8, Encodings.GB18030, Encodings.GBK,
      Encodings.BIG5, Encodings.UTF16LE, Encodings.UTF16BE
    ];
    const buttons: promptAction.Button[] = [];
    for (const encoding of options) {
      buttons.push({
        text: encoding === current ? `${encoding}（当前）` : encoding,
        color: AppColorLiteral.textPrimary
      });
    }

    const title: string = impacted > 0
      ? `${book.title}\n重新分章会删除已有的 ${impacted} 条书签/笔记`
      : `${book.title}\n选择正确的编码后重新分章`;

    try {
      const result = await this.getUIContext().getPromptAction().showActionMenu({
        title: title,
        buttons: buttons as [promptAction.Button, promptAction.Button?, promptAction.Button?,
          promptAction.Button?, promptAction.Button?, promptAction.Button?]
      });
      const picked: string = options[result.index];
      if (picked === undefined || picked === current) {
        return;
      }
      this.toast(`正在按 ${picked} 重新解析…`);
      const ok: boolean = await this.vm.reparseWithEncoding(book.id, picked);
      if (ok) {
        this.toast('重新解析完成，进阅读页确认');
      } else {
        this.toast(this.state.error.length > 0 ? this.state.error : '重新解析失败');
        this.vm.clearError();
      }
    } catch (e) {
      // 用户取消
    }
  }

  private openReader(book: Book): void {
    const param: RouteParam = new RouteParam();
    param.bookId = book.id;
    param.from = RouteName.BOOK_SHELF;
    // 用 @Entry 页面 + Router：ReaderPage 已登记在 resources/base/profile/main_pages.json。
    // 这样不依赖在非 @Entry 文件里 import 另一个 @Entry 页面（ArkTS 不允许）。
    // ⚠️ 走 UIContext 上的 Router，不用已废弃的 @ohos.router 全局函数。
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.READER_PAGE, params: param })
      .catch(() => {
        this.toast('打开阅读页失败');
      });
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }
}
