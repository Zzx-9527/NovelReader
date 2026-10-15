import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { RouteName, RouteParam } from '../model/RouteParam';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { AppFont } from '../common/theme/AppFont';
import { Logger } from '../common/utils/Logger';
import { LoadingView } from '../views/common/LoadingView';
import { EmptyView } from '../views/common/EmptyView';
import { ErrorView } from '../views/common/ErrorView';
import { BookListItem } from '../views/bookshelf/BookListItem';
import { TextInputDialog } from '../views/common/TextInputDialog';
import { ThemeMenu } from '../views/common/ThemeMenu';
import { ThemeConfirm } from '../views/common/ThemeConfirm';

/**
 * 标题左右各留的安全间距（vp）。
 *
 * ⚠️ 与 `ReaderTopBar.TITLE_SIDE_GUTTER` 同一个理由与量级：
 * 标题铺满整宽后要自己居中，长名字会伸到左右控件下面被压住。
 * 取 72 比"‹ 返回"（约 68vp）和 more 图标（约 44vp）都宽，两边都够用。
 */
const TITLE_GUTTER: number = 72;

/**
 * 分组详情页（点书架首页的分组条目进入）。
 *
 * 版面（自上而下）：
 * ```
 * ‹ 返回          科幻            ⋮
 * ─────────────────────────────────────
 * 三体
 * 球状闪电
 * 超新星纪元
 * ...
 * ```
 *
 * ⚠️ 分组在这里是**文件夹**语义，不是筛选条件：
 *  - 首页只显示"分组条目 + 未分组的书"，已归组的书只出现在组内；
 *  - 所以本页就是"打开文件夹看里面的东西"，与首页是两个层级的视图。
 *
 * ⚠️ 书籍列表**逐行显示**（`BookListItem` 的列表形态），
 * 不用网格：组内的书通常不多，逐行能看到完整书名与进度，
 * 而且本页的主操作是"管理这些书"（移出/阅读），逐行更好点。
 *
 * ⚠️ 配色走 `AppColor`（跟随系统深浅色），与书架首页一致 ——
 * 本页属于书架流程，不是阅读页内部（那边才用 `ReaderTheme`）。
 */
@Entry
@Component
struct GroupDetailPage {
  /** 安全区高度（vp），沉浸式全屏的配套让位 */
  @StorageProp('safeAreaTop') safeAreaTop: number = 0;
  @StorageProp('safeAreaBottom') safeAreaBottom: number = 0;

  /**
   * 与书架首页共享的 ViewModel（通过 `ShelfRefreshRegistry` 取）。
   *
   * ⚠️ 不能在本页 `new`：那样移出书籍后首页那份 `state.groups` / `state.books`
   * 不会刷新，返回首页看到的还是旧数量与旧列表。
   */
  private vm: BookShelfViewModel | null = null;

  private groupId: number = -1;
  /**
   * 分组名。
   *
   * ⚠️ 用 `@State` 而不是普通成员：它要显示在标题上，而普通成员的赋值
   * **不触发重绘** —— 首帧会停在初始值上（本项目实测踩过这类差异）。
   */
  @State private groupName: string = '';
  @State private books: Book[] = [];
  @State private loading: boolean = true;
  @State private error: string = '';
  /** 重命名弹窗是否可见 */
  @State private renameVisible: boolean = false;
  /**
   * 主题化菜单/确认弹窗的挂载状态（与 BookShelfPage 同一套做法：
   * 收敛为一份状态，build 里各一个 if）。
   */
  @State private menuVisible: boolean = false;
  @State private menuTitle: string = '';
  @State private menuOptions: string[] = [];
  @State private menuDanger: string = '';
  private menuOnPick: ((index: number) => void) | null = null;
  @State private confirmVisible: boolean = false;
  @State private confirmTitle: string = '';
  @State private confirmMessage: string = '';
  @State private confirmText: string = '确定';
  @State private confirmDanger: boolean = false;
  private confirmOnYes: (() => void) | null = null;
  /** 重命名弹窗的初值 */
  @State private renameInitial: string = '';
  /**
   * 是否处于"编辑分组"（管理组内书籍）模式。
   *
   * ⚠️ 状态字段一律声明在 struct **顶部**，不要散落在方法之间：
   * 集中声明才能一眼看全这个组件有哪些状态（本项目约定）。
   */
  @State private editMode: boolean = false;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as RouteParam | null;
    if (params !== null && params !== undefined) {
      this.groupId = params.groupId;
      /**
       * ⚠️ 名字随路由传进来当**初值**，但仍然会 `loadGroupDetail` 一次
       * （本页需要书籍列表，那次查询顺手就把最新的名字带回来了）。
       * 先给初值是为了首帧标题就有内容，不闪一下空白。
       */
      if (params.groupName.length > 0) {
        this.groupName = params.groupName;
      }
    }
    this.vm = ShelfRefreshRegistry.current;
    if (this.vm === null) {
      this.error = '书架数据已失效，请回书架重试';
      this.loading = false;
      return;
    }
    if (this.groupId < 0) {
      this.error = '缺少分组参数';
      this.loading = false;
      return;
    }
    this.loadAll().catch((e: Object) => {
      this.error = `加载失败：${Logger.errText(e)}`;
      this.loading = false;
    });
  }

  /**
   * 每次回到本页都重载（`onPageShow` 只对 `@Entry` 页面触发）。
   *
   * ⚠️ 必须重载：用户可能从本页进阅读页读了半天再返回，
   * 也可能在别的入口改了分组 —— 不刷新就会显示过期数据。
   */
  onPageShow(): void {
    if (this.vm !== null && this.groupId >= 0) {
      this.loadAll().catch(() => {
      });
    }
  }

  /** 加载分组与组内书籍 */
  private async loadAll(): Promise<void> {
    const vm: BookShelfViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    try {
      const group: BookGroup | null = await vm.loadGroupDetail(this.groupId);
      if (group === null) {
        /**
         * ⚠️ 分组已被删除（用户可能从首页长按删了它）：
         * 必须走错误态而不是显示一个空页面 —— 否则用户会以为
         * "分组还在，只是里面的书没了"，进而去找那些书。
         */
        this.error = '这个分组已不存在';
        this.loading = false;
        return;
      }
      this.groupName = group.name;
      /**
       * ⚠️ 整体替换数组（不原地改）：与首页 `reloadData` 同一个理由 ——
       * `@State` 对数组的原地修改不保证触发重绘。
       */
      this.books = vm.detailBooks;
      this.error = '';
    } catch (e) {
      this.error = `加载失败：${Logger.errText(e as Object)}`;
    } finally {
      this.loading = false;
    }
  }

  /** 打开某本书阅读 */
  private openReader(book: Book): void {
    const param: RouteParam = new RouteParam();
    param.bookId = book.id;
    param.from = RouteName.BOOK_SHELF;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.READER_PAGE, params: param })
      .catch(() => {
        this.toast('打开阅读页失败');
      });
  }

  /**
   * 右上角「更多」菜单。
   *
   * ⚠️ 按钮文案与下标由**同一个数组**推导：插入一项就会"点了 A 执行 B"
   * （设计文档第 28 条）。危险项（解散分组）用 danger 色。
   */
  private showMoreMenu(): void {
    const actions: string[] = ['加入书籍', '编辑分组', '重命名', '解散分组'];

    this.openThemeMenu(`分组「${this.groupName}」`, actions, `${actions.length - 1}`, (index: number) => {
      const picked: string = actions[index];
      if (picked === undefined) {
        return;
      }
      if (picked === '加入书籍') {
        this.openPicker();
      } else if (picked === '编辑分组') {
        this.openEditMode();
      } else if (picked === '重命名') {
        this.renameInitial = this.groupName;
        this.renameVisible = true;
      } else if (picked === '解散分组') {
        this.confirmDissolve();
      }
    });
  }

  /** 打开主题化菜单（与 BookShelfPage 的 openThemeMenu 同一入口语义） */
  private openThemeMenu(title: string, options: string[], danger: string,
    onPick: (index: number) => void): void {
    this.menuTitle = title;
    this.menuOptions = options;
    this.menuDanger = danger;
    this.menuOnPick = onPick;
    this.menuVisible = true;
  }

  /** 打开"加入书籍"页（目标就是本分组） */
  private openPicker(): void {
    const param: RouteParam = new RouteParam();
    param.groupId = this.groupId;
    param.groupName = this.groupName;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.GROUP_PICKER_PAGE, params: param })
      .catch(() => {
        this.toast('打开书籍选择页失败');
      });
  }

  /**
   * 「编辑分组」= 管理组内书籍（移出 / 调整顺序）。
   *
   * ⚠️ 与「重命名」职责**不重叠**：一个管组里的书，一个管组的名字
   * （用户明确区分了这两项）。
   *
   * ⚠️ 当前实现落地为"每行一个「移出」按钮 + 顶部提示"，
   * 不做多选批量：组内书籍通常是个位数到几十本，逐本移出足够，
   * 而多选模式要引入一套独立的选中状态与确认流程 ——
   * 收益不足以抵消复杂度（真要批量，用户可以在首页长按书 →「移入分组」）。
   */
  private openEditMode(): void {
    this.editMode = !this.editMode;
    this.toast(this.editMode ? '点每行的「移出」把书放回书架' : '已退出编辑');
  }

  /** 把一本书移出本分组（回到首页的"未分组"） */
  private async removeFromGroup(book: Book): Promise<void> {
    const vm: BookShelfViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    await vm.moveToGroup(book.id, null);
    await this.loadAll();
    this.toast(`已把《${book.title}》移出分组`);
  }

  /**
   * 长按组内书籍 → 动作菜单。
   *
   * ⚠️ 与书架首页的长按菜单**刻意不同**（用户在本页的语境是"管理组内的书"）：
   *  - 多一项「移出分组」——本页最高频的整理动作；
   *  - 少一项「移入分组」——书已经在这个组里了，要换组回书架长按更合理，
   *    在本页再放一个"选另一个组"的入口会让两处菜单互相打架。
   *
   * ⚠️ 文案与下标由同一个数组推导（设计文档第 28 条）。
   */
  private showBookActions(book: Book): void {
    const actions: string[] = ['开始阅读', '移出分组', '从书架移除'];
    const dangerIndexes: string = '2';

    this.openThemeMenu(book.title, actions, dangerIndexes, (index: number) => {
      const picked: string = actions[index];
      if (picked === undefined) {
        return;
      }
      if (picked === '开始阅读') {
        this.openReader(book);
      } else if (picked === '移出分组') {
        this.removeFromGroup(book);
      } else if (picked === '从书架移除') {
        this.confirmRemoveBook(book);
      }
    });
  }

  /**
   * 从书架移除：**必须二次确认**。
   *
   * ⚠️ 与「移出分组」的区别要在文案里说清：移出分组是"放回书架"（可逆），
   * 从书架移除是"这本书不在书架里了"（进度与标注仍在库里，但用户看不到）。
   * 用户看到"移除"第一反应是"我的书是不是没了"，所以要说清书源文件保留。
   */
  private confirmRemoveBook(book: Book): void {
    this.confirmTitle = `从书架移除《${book.title}》？`;
    this.confirmMessage = '这本书会从书架消失（阅读进度与书签笔记保留在库中，书源文件也不删）。';
    this.confirmText = '移除';
    this.confirmDanger = true;
    this.confirmOnYes = () => {
      const vm: BookShelfViewModel | null = this.vm;
      if (vm === null) {
        return;
      }
      vm.removeBook(book.id).then(() => {
        this.loadAll();
        this.toast('已移出书架');
      }).catch(() => {
        this.toast('移除失败');
      });
    };
    this.confirmVisible = true;
  }

  /**
   * 解散分组（= 删除分组，但书全部保留）。
   *
   * ⚠️ 必须先查**组内书籍数**并写进提示：用户看到"解散分组"第一反应是
   * "我的书会不会没了"。明确告诉他书会回到书架、不会丢，他才敢点。
   */
  private async confirmDissolve(): Promise<void> {
    const count: number = this.books.length;
    const message: string = count > 0
      ? `${count} 本书会回到书架（变成未分组），书和阅读进度都不会丢。`
      : '这个分组是空的，解散后无法恢复。';

    this.confirmTitle = `解散分组「${this.groupName}」？`;
    this.confirmMessage = message;
    this.confirmText = '解散分组';
    this.confirmDanger = true;
    this.confirmOnYes = () => {
      this.runDissolve();
    };
    this.confirmVisible = true;
  }

  /** 解散确认通过后的实际执行（从 confirmDissolve 拆出） */
  private runDissolve(): void {
    const vm: BookShelfViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    vm.deleteGroup(this.groupId).then((moved: number) => {
      if (moved >= 0) {
        /**
         * ⚠️ 解散后**必须返回首页**：本页的分组已经不存在了，
         * 留在这里会是一个"加载失败"的死页面。
         */
        this.getUIContext().getRouter().back();
      } else {
        this.toast(vm.state.error.length > 0 ? vm.state.error : '解散分组失败');
        vm.clearError();
      }
    }).catch(() => {
      this.toast('解散分组失败');
    });
  }

  /** 重命名提交 */
  private async submitRename(name: string): Promise<void> {
    this.renameVisible = false;
    const vm: BookShelfViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    const ok: boolean = await vm.renameGroup(this.groupId, name);
    if (ok) {
      this.groupName = name.trim();
      this.toast('已重命名');
    } else {
      this.toast(vm.state.error.length > 0 ? vm.state.error : '重命名失败');
      vm.clearError();
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  build() {
    Stack() {
      Column() {
        this.buildHeader()
        Divider().color(AppColor.divider)

        if (this.loading) {
          LoadingView({ message: '正在加载…' })
        } else if (this.error.length > 0) {
          ErrorView({
            message: this.error,
            hint: '返回书架看看分组是否还在',
            actionText: '返回书架',
            onRetry: () => {
              this.getUIContext().getRouter().back();
            }
          })
        } else if (this.books.length === 0) {
          /**
           * ⚠️ 空状态包一层带 `layoutWeight(1)` 的 `Column`：
           * `EmptyView` 自身是 `height('100%')`（取父容器高度），
           * 直接放在本页 Column 里会把头部顶出可视区（目录页记过同类坑）。
           */
          Column() {
            EmptyView({
              title: '这个分组还没有书',
              hint: '从书架里挑几本加进来，阅读进度和书签都不会受影响。',
              actionText: '加入书籍',
              onAction: () => {
                this.openPicker();
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
        } else {
          this.buildBookList()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.bgPage)

      // 重命名弹窗（最上层）
      if (this.renameVisible) {
        TextInputDialog({
          title: '重命名分组',
          label: '输入新的分组名',
          placeholder: '分组名，最多 20 字',
          initialValue: this.renameInitial,
          confirmText: '保存',
          onConfirm: (value: string) => {
            this.submitRename(value);
          },
          onCancel: () => {
            this.renameVisible = false;
          }
        })
      }

      // 主题化动作菜单（替代系统 showActionMenu）
      if (this.menuVisible) {
        ThemeMenu({
          title: this.menuTitle,
          options: this.menuOptions,
          dangerIndexes: this.menuDanger,
          currentIndex: -1,
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

      // 主题化确认弹窗（替代系统 showDialog）
      if (this.confirmVisible) {
        ThemeConfirm({
          title: this.confirmTitle,
          message: this.confirmMessage,
          confirmText: this.confirmText,
          danger: this.confirmDanger,
          onConfirm: () => {
            this.confirmVisible = false;
            const cb = this.confirmOnYes;
            if (cb !== null) {
              cb();
            }
          },
          onCancel: () => {
            this.confirmVisible = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    /**
     * ⚠️ 背景色必须挂在**这一层**（与 padding / expandSafeArea 同一个节点）。
     *
     * 原来只在里面的 `Column` 上设了 `bgPage`，而让出状态栏的 padding 在
     * 这个 Stack 上 —— Stack 铺满全屏（含状态栏）却没有底色，那条被让出的
     * 区域露的是**窗口底色（白）**，于是页面顶部出现一条白带、
     * 看起来"没有沉浸式"。背景挂在带 padding 的节点上时，
     * 底色会连 padding 一起铺满，这才是沉浸式该有的样子
     * （`Index.ets` 的主页正是这么写的）。
     */
    .backgroundColor(AppColor.bgPage)
    .padding({ top: this.safeAreaTop, bottom: this.safeAreaBottom })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 头部：左返回、中标题、右「更多」。
   *
   * ⚠️ 用 `Stack` 让标题**相对整屏居中**，而不是 `Row` + `layoutWeight`：
   * 左右控件宽度不等（"‹ 返回"比图标宽），`Row` 里居中会偏向一侧。
   * 这是 `ReaderTopBar` / 目录页共用的同一套做法。
   *
   * ⚠️ 标题左右留 `TITLE_GUTTER` 内边距：长分组名会伸到两侧控件下面被压住，
   * 留出这段安全区，文本就会在碰到按钮前先省略号截断。
   */
  @Builder
  buildHeader() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.groupName.length > 0 ? this.groupName : '分组')
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ left: TITLE_GUTTER, right: TITLE_GUTTER })

      /**
       * 上层：铺满整宽的行，把左右控件顶到两端。
       *
       * ⚠️ 放在标题**之后**画 = 叠在标题上层，这样两个控件一定拿得到点击
       * （`HitTestMode.Default` 下后画的节点优先命中）。
       */
      Row() {
        Text('‹ 返回')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppColor.textPrimary)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Blank()

        /**
         * 「N 本」计数：**贴在头部右侧**（用户要求移到右边）。
         *
         * ⚠️ 放在「更多」按钮左侧而不是标题下面：标题保持单行居中，
         * 计数作为一个安静的数字靠右，与返回/更多两个控件同排 ——
         * 头部一行说完"这里有什么、有多少"。
         */
        Text(`${this.books.length} 本`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textHint)
          .fontFeature(AppFont.TABULAR)
          .padding({ left: 4, right: 2 })

        /**
         * 「更多」：用 `more.svg`（三点竖排），`fillColor` 染色跟随主题。
         *
         * ⚠️ **绝不要给这个固定尺寸的 `Image` 加 `padding`**（本项目实测踩过）：
         * `Image` 显式设了 `width(20).height(20)` 后，`padding` 是**向内挤**的 ——
         * 左右各 12 就是 24，比 20 还大，内容区被压成 0，图标**整个画不出来**
         * （表现就是"代码明明在，屏幕上是空的"）。
         *
         * 对比 `ReaderTopBar` 的 `↻`：那是个 `Text`，尺寸由字号与 padding
         * 共同撑开，所以给它加 padding 是安全的。两者机制不同，别照搬。
         *
         * ⚠️ 点击热区靠**外层 `Row`** 撑开（padding 加在 `Row` 上、
         * `onClick` 也绑在 `Row` 上）：44vp 是移动端最小可点尺寸的经验值，
         * 只有 20vp 的图标直接当按钮太难点中。
         */
        Row() {
          Image($r('app.media.more'))
            .width(20)
            .height(20)
            .objectFit(ImageFit.Contain)
            .fillColor(AppColor.textPrimary)
        }
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .onClick(() => {
          this.showMoreMenu();
        })
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(48)
  }

  /** 组内书籍列表：**逐行显示** */
  @Builder
  buildBookList() {
    Column() {
      /**
       * 编辑模式的提示条。
       *
       * ⚠️ 必须有：进入编辑后每行多出一个「移出」按钮，
       * 不给提示用户会以为界面坏了（或不知道自己刚点了什么）。
       */
      if (this.editMode) {
        Row() {
          Text('点每行的「移出」把书放回书架')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textSecondary)
            .layoutWeight(1)
          Text('完成')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.accent)
            .padding({ left: 12, right: 4, top: 4, bottom: 4 })
            .onClick(() => {
              this.editMode = false;
            })
        }
        .width('100%')
        .padding({
          left: AppTheme.PAGE_PADDING,
          right: AppTheme.PAGE_PADDING,
          top: AppTheme.GAP_S,
          bottom: AppTheme.GAP_S
        })
      }

      List({ space: AppTheme.GAP_S }) {
        ForEach(this.books, (book: Book) => {
          ListItem() {
            Row({ space: AppTheme.GAP_S }) {
              /**
               * ⚠️ 复用 `BookListItem` 并给它 `layoutWeight(1)`：
               * 编辑模式下右侧要放「移出」，条目必须让出宽度。
               * 直接给它固定宽度会与右侧按钮重叠。
               */
              Column() {
                BookListItem({
                  book: book,
                  onTap: (b: Book) => {
                    this.openReader(b);
                  },
                  /**
                   * ⚠️ **必须传 `onLongPress`**：`BookListItem` 内部的长按手势
                   * 只在回调存在时才有意义（组件用 `if (this.onLongPress !== undefined)`
                   * 判断），不传就是"长按完全没反应"——本页此前正是这个漏传。
                   *
                   * 菜单项与书架首页的长按菜单**刻意不同**：这里多了
                   * 「移出分组」（在本页语境下最常用），少了「移入分组」
                   * （已经在分组里了，要换组回书架长按更合理）。
                   */
                  onLongPress: (b: Book) => {
                    this.showBookActions(b);
                  }
                })
              }
              .layoutWeight(1)

              if (this.editMode) {
                Text('移出')
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppColor.danger)
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .onClick(() => {
                    this.removeFromGroup(book);
                  })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
        }, (book: Book) => book.listKey())
      }
      .width('100%')
      .layoutWeight(1)
      .padding({
        left: AppTheme.PAGE_PADDING,
        right: AppTheme.PAGE_PADDING,
        top: AppTheme.GAP_S,
        bottom: AppTheme.GAP_L
      })
      .cachedCount(6)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }
}
