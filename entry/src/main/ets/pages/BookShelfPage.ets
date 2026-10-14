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
import { TextInputDialog } from '../views/common/TextInputDialog';
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

  /**
   * 分组管理弹窗是否可见。
   *
   * ⚠️ 这些是**本页的临时交互状态**，不进 `ShelfState`：
   * 它们只服务一次弹窗交互，与书架数据无关；放进 `@Observed` 状态对象
   * 会让"打开一个弹窗"也去驱动整个书架列表重绘。
   */
  @State private groupDialogVisible: boolean = false;
  /** 弹窗是"新建"还是"重命名"；重命名时用 `editingGroupId` 记住改的是哪一个 */
  @State private editingGroupId: number = -1;
  /** 重命名时输入框的初值 */
  @State private editingGroupName: string = '';

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
    /**
     * ⚠️ 外层用 `Stack` 是为了让分组弹窗能**盖住整页**。
     *
     * 若把弹窗作为 `Column` 的最后一个子节点，它会参与布局、把上面的列表挤短
     * （弹窗自己 `height('100%')`，会把父容器撑爆）；而 `Stack` 是层叠语义，
     * 后画的浮层盖在前面内容之上，不影响列表布局 —— 与 `ReaderPage` 的分层
     * 是同一套做法。
     */
    Stack() {
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

      /**
       * 分组新建/重命名弹窗（最上层）。
       *
       * ⚠️ 用同一个弹窗承载"新建"与"重命名"两种用途，靠 `editingGroupId`
       * 区分（-1 = 新建）—— 两者的界面与校验完全一样，
       * 做两个组件只会让"改了一处忘了另一处"。
       */
      if (this.groupDialogVisible) {
        TextInputDialog({
          title: this.editingGroupId < 0 ? '新建分组' : '重命名分组',
          label: this.editingGroupId < 0 ? '' : '输入新的分组名',
          placeholder: '分组名，最多 20 字',
          initialValue: this.editingGroupName,
          confirmText: this.editingGroupId < 0 ? '创建' : '保存',
          onConfirm: (value: string) => {
            this.submitGroupDialog(value);
          },
          onCancel: () => {
            this.groupDialogVisible = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
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

        /**
         * 「管理」入口放在 chips 行**末尾**，而不是标题行：
         *
         * ⚠️ 它是**低频**操作（建组/改名/删组），放进标题行会和"导入/排序/
         * 网格切换"这几个高频操作抢注意力；而分组这一行的语义本来就是
         * "与分组有关的事"，放这里用户找得到、又不干扰日常。
         *
         * ⚠️ 长按分组标签也能改名/删除（见 `showGroupActions`），
         * 这是给"只想改一个组"的快捷路径；本入口负责"新建"与总览。
         */
        Text('＋ 管理')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .onClick(() => {
            this.showGroupManageMenu();
          })
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
      /**
       * ⚠️ 长按进入分组管理（仅真实分组，不含"全部"）。
       *
       * 为什么用长按而不是给每个标签加一个小按钮：标签本身很窄
       * （`CHIP_RADIUS` 的胶囊），塞进按钮会把点击热区切碎、容易误触；
       * 而"长按某个标签 → 改它/删它"是移动端的通用心智，
       * 也与书籍项的长按菜单（`showBookActions`）保持一致。
       *
       * ⚠️ "全部"（groupId < 0）没有长按菜单：它是虚拟分组，
       * 既不能改名也不能删除。
       */
      .gesture(
        LongPressGesture()
          .onAction(() => {
            if (groupId < 0) {
              return;
            }
            this.showGroupActions(groupId, label);
          })
      )
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

  /**
   * 导入 TXT：选文件 → 解析 → **跳确认页**（不再直接入库）。
   *
   * ⚠️ 为什么必须经过确认页，而不是"选完就入库 + toast 提示"：
   * 自动编码探测不可能对每个 TXT 都准确，而**编码错了正文就是满屏乱码**。
   * 旧流程只弹一个 toast 说"编码识别为 X"，用户既无法核对分章结果、
   * 也无法在入库前改编码 —— 只能等导入完、进阅读页发现乱码、再回书架长按换编码
   * （那还会连带删掉标注）。确认页把这一步提前到"写库之前"，代价是点一次"导入"。
   *
   * ⚠️ 低置信度不再用 toast 提示：确认页会把编码与分章预览一起摊开给用户看，
   * 比一句一闪而过的提示有用得多（toast 只是"告知"，确认页是"让他确认"）。
   */
  private async doImport(): Promise<void> {
    const preparation = await this.vm.pickAndPrepare();
    if (preparation === null) {
      if (this.state.error.length > 0) {
        this.toast(this.state.error);
        this.vm.clearError();
      }
      return;
    }
    this.openImportConfirm();
  }

  /**
   * 打开导入确认页。
   *
   * ⚠️ 待确认的 `preparation` 由 ViewModel 的 `state.pendingImport` 携带，
   * **不通过路由参数传**：它是含上千个章节对象的复杂结构，
   * 塞进 `router` 的 params 会被序列化/拷贝，既慢又可能丢字段。
   * 路由只负责"打开页面"，数据靠共享的 ViewModel 交接 ——
   * 与 `ReaderJumpRegistry` 的做法同一个理由（复杂数据不走路由）。
   *
   * ⚠️ 确认页取消时负责 `discardPendingImport()` 清理沙箱文件；
   * 本页不清理，否则用户还没看到确认页文件就没了。
   */
  private openImportConfirm(): void {
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.IMPORT_CONFIRM_PAGE })
      .catch(() => {
        // 确认页打不开（理论上不会，已登记在 main_pages.json）：
        // 退回"直接入库"的旧行为，至少不把用户的导入卡死
        this.toast('无法打开确认页，正在直接导入…');
        // ⚠️ 接住 Promise：不接的话失败会被完全静默吞掉（设计文档第 26 条）
        this.commitImportDirectly().catch((e: Object) => {
          this.toast(`导入失败：${Logger.errText(e)}`);
        });
      });
  }

  /** 确认页不可用时的兜底：按探测到的编码直接入库 */
  private async commitImportDirectly(): Promise<void> {
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
   * ⚠️ **必须二次确认**：重新分章会因外键 `ON DELETE CASCADE` 连带删除该书
   * 全部书签/笔记，而这是**不可撤销**的。早期只在菜单标题里写一行提示就直接执行
   * （设计文档 §P1 明确要求"书签功能上线后必须补确认弹窗"）—— 书签已经上线，
   * 所以这里补上。标题里的提示不算确认：用户点编码时视线在选项上，
   * 一行小字很容易被忽略，而代价是丢掉全部标注。
   *
   * 流程：选编码 → （有标注时）确认删除 → 执行。
   * 没有标注时不弹确认：此时没有可丢的东西，多一次点击只是打扰。
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
      /**
       * ⚠️ 确认放在"选完编码之后"，不是点菜单时：
       * 用户此时才真的决定要重解析，而且能看到自己选了哪个编码。
       */
      if (impacted > 0 && !(await this.confirmAnnotationLoss(impacted))) {
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

  /**
   * 二次确认：重解析会删掉 N 条书签/笔记。
   *
   * ⚠️ 用 `showDialog` 而不是 `showActionMenu`：菜单的语义是"从若干平级选项里挑一个"，
   * 而这里是**是非确认**，且必须给出"取消"这个明确的退路。
   * 按钮顺序按系统约定：第 0 个是 positiveButton（确认），第 1 个是 negativeButton（取消）。
   *
   * ⚠️ 危险动作放在**第二个按钮**（非默认位），且用 `danger` 色：
   * 避免用户习惯性地按第一个按钮就把标注删了。
   *
   * @returns 用户是否确认继续
   */
  private async confirmAnnotationLoss(count: number): Promise<boolean> {
    const buttons: [promptAction.Button, promptAction.Button] = [
      { text: '取消', color: AppColorLiteral.textPrimary },
      { text: '删除并重新分章', color: AppColorLiteral.danger }
    ];
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: '确认重新分章？',
        message: `这本书的 ${count} 条书签/笔记会一并被删除，且无法恢复。`,
        buttons: buttons
      });
      // index === 1 才是"删除并重新分章"
      return result.index === 1;
    } catch (e) {
      // 用户取消或弹窗失败：一律当作"不继续"，绝不默认执行破坏性操作
      return false;
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

  // ------------------------------------------------------------ 分组管理

  /**
   * 「管理」入口：新建分组 / 管理已有分组。
   *
   * ⚠️ 用 `showActionMenu` 且按钮是**动态拼**的：
   * `buttons` 的类型是六元组（第 1 个必填、其余可选），所以先把要显示的项
   * 收集进数组，再断言成元组 —— 与 `showEncodingPicker` 同一套写法。
   *
   * 注意：这里的按钮文案与下标**必须由同一个数组推导**，不能各写一份，
   * 否则以后插入一项就会"点了 A 执行 B"（设计文档第 28 条）。
   */
  private showGroupManageMenu(): void {
    const actions: string[] = ['新建分组'];
    // 有分组时才给"管理已有分组"：一个都没有时它点开是空的，属于死路
    if (this.state.groups.length > 0) {
      actions.push('重命名 / 删除分组');
    }

    const buttons: promptAction.Button[] = [];
    for (const action of actions) {
      buttons.push({ text: action, color: AppColorLiteral.textPrimary });
    }

    this.getUIContext().getPromptAction().showActionMenu({
      title: '分组管理',
      buttons: buttons as [promptAction.Button, promptAction.Button?]
    }).then((result) => {
      const picked: string = actions[result.index];
      if (picked === '新建分组') {
        this.openCreateGroupDialog();
      } else if (picked === '重命名 / 删除分组') {
        this.showGroupPickerForManage();
      }
    }).catch(() => {
      // 用户取消
    });
  }

  /**
   * 选一个分组去管理（重命名/删除）。
   *
   * ⚠️ 分组可能很多，而 `showActionMenu` 最多六项 —— 所以先按名字列出，
   * 超出部分截断并提示。真正要"管理很多分组"需要独立管理页（见设计文档待办），
   * 这里先覆盖常见数量（几个到十几个）。
   */
  private showGroupPickerForManage(): void {
    const groups: BookGroup[] = this.state.groups;
    const maxItems: number = 6;
    const shown: BookGroup[] = groups.slice(0, maxItems);

    const buttons: promptAction.Button[] = [];
    for (const group of shown) {
      buttons.push({ text: group.name, color: AppColorLiteral.textPrimary });
    }

    const truncated: boolean = groups.length > shown.length;
    const title: string = truncated
      ? `选择要管理的分组（仅显示前 ${shown.length} 个）`
      : '选择要管理的分组';

    this.getUIContext().getPromptAction().showActionMenu({
      title: title,
      buttons: buttons as [promptAction.Button, promptAction.Button?, promptAction.Button?,
        promptAction.Button?, promptAction.Button?, promptAction.Button?]
    }).then((result) => {
      const group: BookGroup = shown[result.index];
      if (group === undefined) {
        return;
      }
      this.showGroupActions(group.id, group.name);
    }).catch(() => {
      // 用户取消
    });
  }

  /**
   * 单个分组的操作菜单：重命名 / 删除。
   *
   * @param groupId 分组 id
   * @param name    当前名字（用于菜单标题与重命名初值）
   */
  private showGroupActions(groupId: number, name: string): void {
    const actions: string[] = ['重命名', '删除分组'];

    const buttons: promptAction.Button[] = [
      { text: actions[0], color: AppColorLiteral.textPrimary },
      { text: actions[1], color: AppColorLiteral.danger }
    ];

    this.getUIContext().getPromptAction().showActionMenu({
      title: `分组「${name}」`,
      buttons: buttons as [promptAction.Button, promptAction.Button?, promptAction.Button?,
        promptAction.Button?, promptAction.Button?, promptAction.Button?]
    }).then(async (result) => {
      const picked: string = actions[result.index];
      if (picked === '重命名') {
        this.openRenameGroupDialog(groupId, name);
      } else if (picked === '删除分组') {
        await this.confirmDeleteGroup(groupId, name);
      }
    }).catch(() => {
      // 用户取消
    });
  }

  private openCreateGroupDialog(): void {
    this.editingGroupId = -1;
    this.editingGroupName = '';
    this.groupDialogVisible = true;
  }

  private openRenameGroupDialog(groupId: number, name: string): void {
    this.editingGroupId = groupId;
    this.editingGroupName = name;
    this.groupDialogVisible = true;
  }

  /**
   * 弹窗确认：新建或重命名（由 `editingGroupId` 决定走哪条路）。
   *
   * ⚠️ 两条路都**必须检查返回值**并给出反馈：
   * 重名是用户最容易犯的错（"我已经建过一个了"），静默失败会让他以为没生效。
   */
  private async submitGroupDialog(name: string): Promise<void> {
    this.groupDialogVisible = false;
    if (this.editingGroupId < 0) {
      const newId: number = await this.vm.createGroup(name);
      if (newId > 0) {
        this.toast('分组已创建');
      } else if (this.state.error.length > 0) {
        this.toast(this.state.error);
        this.vm.clearError();
      }
      return;
    }
    const ok: boolean = await this.vm.renameGroup(this.editingGroupId, name);
    if (ok) {
      this.toast('已重命名');
    } else if (this.state.error.length > 0) {
      this.toast(this.state.error);
      this.vm.clearError();
    }
  }

  /**
   * 删除分组前的二次确认。
   *
   * ⚠️ 必须先查**组内书籍数**并写进提示：删除分组**不会删书**（成员会被置为
   * 未分组），但用户看到"删除分组"第一反应是"我的书会不会没了"。
   * 明确告诉他有几本书会被移出、书本身保留，他才敢点。
   */
  private async confirmDeleteGroup(groupId: number, name: string): Promise<void> {
    let count: number = 0;
    try {
      count = await this.vm.countInGroup(groupId);
    } catch (e) {
      // 查不到数量不该挡住删除：退化成不带数量的提示
      count = 0;
    }

    const message: string = count > 0
      ? `组内 ${count} 本书会移到「未分组」，书和阅读进度都不会丢。`
      : '这个分组是空的，删除后无法恢复。';

    const buttons: [promptAction.Button, promptAction.Button] = [
      { text: '取消', color: AppColorLiteral.textPrimary },
      { text: '删除分组', color: AppColorLiteral.danger }
    ];

    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: `删除分组「${name}」？`,
        message: message,
        buttons: buttons
      });
      if (result.index !== 1) {
        return;
      }
      const moved: number = await this.vm.deleteGroup(groupId);
      if (moved >= 0) {
        this.toast(count > 0 ? `已删除分组，${moved} 本书移到未分组` : '分组已删除');
      } else {
        this.toast(this.state.error.length > 0 ? this.state.error : '删除分组失败');
        this.vm.clearError();
      }
    } catch (e) {
      // 用户取消
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }
}
