// 仅用其**类型**（promptAction.Button）—— 调用一律走
// this.getUIContext().getPromptAction()，全局函数已废弃（见 §5.6 第 19 条）
import { promptAction } from '@kit.ArkUI';
import { Book } from '../model/Book';
import { BookGroup } from '../model/BookGroup';
import { ShelfEntry } from '../model/ShelfEntry';
import { ShelfState } from '../viewmodels/ShelfState';
import { BookShelfViewModel } from '../viewmodels/BookShelfViewModel';
import { ShelfRefreshRegistry } from '../viewmodels/ShelfRefreshRegistry';
import { BookSort } from '../data/repository/BookRepository';
import { StorageBootstrap } from '../common/StorageBootstrap';
import { AppColor, AppColorLiteral, AppTheme } from '../common/theme/AppTheme';
import { AppFont } from '../common/theme/AppFont';
import { Encodings } from '../common/utils/EncodingDetector';
import { Logger } from '../common/utils/Logger';
import { LoadingView } from '../views/common/LoadingView';
import { EmptyView } from '../views/common/EmptyView';
import { ErrorView } from '../views/common/ErrorView';
import { BookGridItem } from '../views/bookshelf/BookGridItem';
import { BookListItem } from '../views/bookshelf/BookListItem';
import { GroupGridItem } from '../views/bookshelf/GroupGridItem';
import { GroupListItem } from '../views/bookshelf/GroupListItem';
import { ContinueReadingCard } from '../views/bookshelf/ContinueReadingCard';
import { ShelfSkeleton } from '../views/bookshelf/ShelfSkeleton';
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

        /**
         * ⚠️ 加载态与错误态的判据都要求"**完全没有内容**"
         * （分组与散书都为 0），不能只看 `books`。
         *
         * 只看 `books` 的话：一个只有分组、没有散书的书架在刷新时会
         * 闪出"正在加载书架…"，出错时更是整屏替换成错误页 ——
         * 而分组条目明明还能正常点进去。判据要覆盖**这一页实际会渲染的东西**。
         */
        if (this.state.loading && this.state.books.length === 0
          && this.state.groups.length === 0) {
          /**
           * ⚠️ 首屏加载与"重新解析"**必须分开**，不能用同一个占位：
           *
           *  - 首次加载 → **骨架屏**（`ShelfSkeleton`）：它按真实版面铺块，
           *    加载完成时是"占位块被内容替换"，位置与尺寸都不变，零跳变；
           *  - 重新解析 → 保留转圈 + 文案：这是一个**有明确文案的过程**
           *    （用户刚点完"换编码"，需要知道正在做什么），
           *    而它的时长不可预测（大文件可能十几秒），骨架屏在这里
           *    反而会让人以为"书已经在加载了"。
           *
           * 判据：**知道要出现什么形状 → 骨架屏；只知道"在处理" → 转圈 + 文案。**
           */
          if (this.state.reparsing) {
            LoadingView({ message: '正在重新解析…' })
          } else {
            ShelfSkeleton()
          }
        } else if (this.state.error.length > 0 && this.state.books.length === 0
          && this.state.groups.length === 0) {
          ErrorView({
            message: this.state.error,
            /**
             * ⚠️ 提示里必须补上「已导入的文件不会丢失」。
             *
             * 书架报错时，用户最怕的不是"读不出来"，而是"我的书是不是没了" ——
             * 而这两件事在这里是完全独立的：错误来自**读库/读索引**，
             * 书源文件一直躺在沙箱里。把这句话说在前面，用户才敢按"重试"
             * 而不是先去文件管理器翻。
             *
             * 判据：**错误文案要同时说"怎么了"和"我最怕的那件事没发生"**，
             * 只给一个动作（重试）是不够的。
             */
            hint: '下拉重试，或检查存储权限。已导入的文件不会丢失。',
            actionText: '重试',
            onRetry: () => {
              this.vm.clearError();
              this.vm.refresh();
            }
          })
        } else if (this.state.isEmptyShelf) {
          /**
           * **首页完全为空** → 引导导入。
           *
           * ⚠️ 判据是 `isEmptyShelf`，它同时看**分组与散书**：
           * 只有分组、没有散书时不该显示这一屏 —— 用户会以为分组也没了，
           * 而分组恰恰是他自己建的。
           */
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

  /**
   * 标题行下方的**计数副标题**。
   *
   * ⚠️ 空书架时返回空串、调用方整行不渲染：
   * 首屏加载中书架是空的，此时显示「0 本」会与骨架屏自相矛盾
   * （骨架屏说"马上有一屏书"，副标题说"一本都没有"）。
   * 而真的空书架会走 `EmptyView` 那一屏，也不需要这个计数。
   *
   * ⚠️ 用「组」而不是「个分组」：标题行右侧还有四个操作，
   * 副标题的可用宽度只有一百多 vp，多两个字就会被省略号截断。
   */
  private shelfCountText(): string {
    const books: number = this.state.books.length;
    const groups: number = this.state.groups.length;
    if (books === 0 && groups === 0) {
      return '';
    }
    if (groups === 0) {
      return `${books} 本`;
    }
    return `${books} 本 · ${groups} 组`;
  }

  /**
   * 头部：标题 + 计数 + 操作，下面一条**通栏发丝线**。
   *
   * ⚠️ 本次从"一行挤下标题与四个操作"改成**两行**，理由是量出来的：
   * 三个胶囊（约 50 / 50 / 62vp）+「导入」（约 56vp）+ 四个 8vp 间距
   * 已经占掉 218+32 = 250vp，而整行可用 328vp —— 留给标题的只有 78vp。
   * 「书架」占 40vp，副标题需要约 76vp，**零余量**：任何字体差异都会
   * 把计数截成省略号。分两行之后标题拿到全部宽度，操作行也不必再压字号。
   *
   * ⚠️ 发丝线**通栏**（左右都不留 16vp 内边距）：它是一条"版面分隔"，
   * 而不是某个块的外框。出血到屏幕两边才读得出这个意思。
   * 为此它必须挂在**不带内边距**的容器上，所以本 `@Builder` 分了三段：
   * 带内边距的标题行 / 通栏线 / 带内边距的后续块。
   */
  @Builder
  buildHeader() {
    Column() {
      // ① 标题 + 计数 + 导入
      Row({ space: AppTheme.GAP_S }) {
        Column({ space: 4 }) {
          Text('书架')
            .fontSize(AppTheme.FONT_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
            // 标题落衬线（探测到才有）：与书名、分组名同一套题字语汇
            .fontFamily(AppFont.titleFamily())
            .letterSpacing(AppTheme.TRACK_TITLE)

          if (this.shelfCountText().length > 0) {
            Text(this.shelfCountText())
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppColor.textHint)
              .fontFeature(AppFont.TABULAR)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        /**
         * 「导入」：**朱色文字动作**，不是实心按钮。
         *
         * ⚠️ 从实心 `primary` 按钮降级为文字动作的理由：操作行改成
         * 朱色文字语汇后（见②），「导入」再保留实心底就是这一屏
         * 最重的元素 —— 而导入是低频动作，不该比"继续阅读"更重。
         * 三个动作统一"朱色文字 + 8vp 热区"，主次交给「继续阅读」卡。
         */
        Text('导入')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .enabled(!this.state.importing)
          .opacity(this.state.importing ? 0.4 : 1)
          .onClick(() => {
            this.doImport();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: AppTheme.PAGE_PADDING,
        right: AppTheme.PAGE_PADDING,
        top: AppTheme.GAP_M
      })

      /**
       * ② 操作行：**朱色文字动作**，不再是描边胶囊。
       *
       * ⚠️ 从"1vp 描边胶囊"改成裸文字的理由：三个胶囊 + 导入按钮
       * 把标题区下缘挤成一条"控件带"，描边让每个动作都带着一圈框，
       * 视觉重量全在框上而不是字上。改成文字动作后，
       * "可点"由**颜色**（accent，全页唯一彩色）表达，边界由 8vp 热区承担 ——
       * 与"朱砂只用于小面积"的纪律一致，也更安静。
       */
      Row({ space: AppTheme.GAP_L }) {
        Text(this.state.gridMode ? '列表' : '网格')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
          .padding({ left: 2, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.vm.toggleGridMode();
          })

        Text('排列')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
          .padding({ left: 2, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.showSortMenu();
          })

        Text('＋ 新建分组')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
          .padding({ left: 2, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.openCreateGroupDialog();
          })
      }
      .width('100%')
      .padding({
        left: AppTheme.PAGE_PADDING,
        right: AppTheme.PAGE_PADDING,
        top: 0,
        bottom: AppTheme.GAP_S
      })

      // ③ 通栏发丝线
      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(AppColor.divider)

      /**
       * ④ 状态文案 + 继续阅读卡片。
       *
       * 这两块都必须自己带左右内边距：它们已经不在①③的带内边距容器里了。
       */
      if (this.state.importMessage.length > 0) {
        Text(this.state.importMessage)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.textSecondary)
          .width('100%')
          .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })
      }

      if (this.state.reparseMessage.length > 0) {
        Text(this.state.reparseMessage)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppColor.accent)
          .width('100%')
          .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })
      }

      /**
       * 继续阅读卡片。
       *
       * ⚠️ 它显示的是**全局**最近在读的一本，不受分组影响 —— 这是对的：
       * 首页本身就是"全部内容"的视图（分组与未分组的书都在这里列），
       * 所以"最近在读哪本"在这里显示没有任何矛盾。
       *
       * ⚠️ 与早期实现的区别：那时分组是**筛选条件**，在"某个分组"视图下
       * 显示一本组外的书会自相矛盾（用户实测反馈过）；
       * 现在分组是**文件夹**（点进去才筛选），首页不存在"当前分组"，
       * 这个矛盾自然消失了。
       *
       * ⚠️ 外面套一层带内边距的 `Column`，而不是给卡片传 margin ——
       * `@Prop`/普通成员的组件不该由调用方决定外边距，
       * 与"组件管画什么、容器管放在哪"是同一条分工。
       */
      if (this.state.continueBook !== null) {
        Column() {
          ContinueReadingCard({
            book: this.state.continueBook ?? undefined,
            onContinue: (book: Book) => {
              this.openReader(book);
            }
          })
        }
        .width('100%')
        .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING, top: AppTheme.GAP_M })
      }
    }
    .width('100%')
  }

  /**
   * 点分组条目 → 进入分组详情页。
   *
   * ⚠️ 名字随路由一起传：目标页要立刻在标题上显示它，
   * 而"自己去查库"是异步的，首帧会先渲染成空标题（详见 `RouteParam.groupName`）。
   */
  private openGroupDetail(group: BookGroup): void {
    const param: RouteParam = new RouteParam();
    param.groupId = group.id;
    param.groupName = group.name;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.GROUP_DETAIL_PAGE, params: param })
      .catch(() => {
        this.toast('打开分组失败');
      });
  }

  // ------------------------------------------------------------ 书籍列表

  /**
   * 书架首页列表：**分组与书籍混排**。
   *
   * ⚠️ 只遍历 `state.entries` 这**一条**数组，而不是"分组一个 `ForEach`、
   * 书一个 `ForEach`"。
   *
   * 后者无论各自怎么排，渲染出来永远是"分组全在前、书全在后" ——
   * 做不到交错，而用户明确要求"分组就相当于一本书"：
   * 刚读完的书必须能排在分组**前面**（用户实测反馈过这一点）。
   *
   * ⚠️ 排序已在 ViewModel 里做完（`buildEntries`），这里**不再排序**：
   * 渲染层只负责画，排序规则收在一处（设计文档第 28 条）。
   * 若在这里再排一次，两处规则迟早会不一致。
   */
  @Builder
  buildBookList() {
    if (this.state.gridMode) {
      Grid() {
        ForEach(this.state.entries, (entry: ShelfEntry) => {
          GridItem() {
            /**
             * ⚠️ 按 `isGroup` 分流到两个组件，而不是做一个"万能条目"：
             * 分组与书的**封面逻辑、角标、长按菜单**都不同，
             * 塞进一个组件会到处是 `if (isGroup)`，越写越难读。
             */
            if (entry.isGroup) {
              GroupGridItem({
                group: entry.group,
                onTap: (g: BookGroup) => {
                  this.openGroupDetail(g);
                },
                onLongPress: (g: BookGroup) => {
                  this.showGroupActions(g.id, g.name);
                }
              })
            } else {
              BookGridItem({
                book: entry.book,
                onTap: (b: Book) => {
                  this.openReader(b);
                },
                onLongPress: (b: Book) => {
                  this.showBookActions(b);
                }
              })
            }
          }
        }, (entry: ShelfEntry) => entry.key())
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
      /**
       * 列表形态：**整列收成一块卡片**，行与行之间用一根缩进发丝线分开。
       *
       * ⚠️ 原实现是 `List({ space: 8 })` + 每行自己一张 `bgCard` 圆角卡，
       * 六行就是"六张白卡叠在浅灰底上"—— 白/灰交替出现，整列读起来是碎的，
       * 而且**每张卡都在重复表达同一个边界**（这一列本来就是一个整体）。
       *
       * 现在把卡片底挪到 `List` 自己身上：一列只有一条外边界，
       * 内部靠"从文字列开始的缩进线"分区。缩进线而不是通栏线，是因为
       * 通栏线等于又把整块切成一行行的卡 —— 封面那一列必须保持连续，
       * 视觉上才说得通"这是一排书"。
       *
       * ⚠️ 卡片底 + 圆角 + `clip` 都挂在 `List` 上（不是外层 `Column`）：
       * 挂在 `List` 上才能让**滚动内容一起被裁**；挂在外层则滚动时
       * 行会从圆角外面滑出来。这也是把内边距留给外层 `Column` 的原因。
       *
       * ⚠️ `space` 必须去掉（默认 0）：行间现在靠发丝线分区，
       * 再留 8vp 间距会让线悬在两段空白之间，读起来像"断开的表格"。
       */
      Column() {
        List() {
          /**
           * ⚠️ `ForEach` 的 itemGenerator 这里**必须**收第二个参数 `index`：
           * 首行不画线（否则线会顶在卡片上边缘，看起来像卡片缺了个边）。
           * 用 `entry.key()` 做键 —— 排序变化时键跟着变，实例重建，
           * `topRule` 才会跟着重新求值。
           */
          ForEach(this.state.entries, (entry: ShelfEntry, index: number) => {
            ListItem() {
              if (entry.isGroup) {
                GroupListItem({
                  group: entry.group,
                  inset: true,
                  topRule: index > 0,
                  onTap: (g: BookGroup) => {
                    this.openGroupDetail(g);
                  },
                  onLongPress: (g: BookGroup) => {
                    this.showGroupActions(g.id, g.name);
                  }
                })
              } else {
                BookListItem({
                  book: entry.book,
                  inset: true,
                  topRule: index > 0,
                  onTap: (b: Book) => {
                    this.openReader(b);
                  },
                  onLongPress: (b: Book) => {
                    this.showBookActions(b);
                  }
                })
              }
            }
          }, (entry: ShelfEntry) => entry.key())
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(AppColor.bgCard)
        .borderRadius(AppTheme.CARD_RADIUS)
        .clip(true)
        .cachedCount(6)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({
        left: AppTheme.PAGE_PADDING,
        right: AppTheme.PAGE_PADDING,
        top: AppTheme.GAP_M,
        bottom: AppTheme.GAP_L
      })
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

  /**
   * 长按书籍的动作菜单。
   *
   * ⚠️ 按钮文案与下标**必须由同一个数组推导**，不能各写一份：
   * 插入一项就会"点了 A 执行 B"（设计文档第 28 条）。
   * 所以这里先收集要显示的项，再用同一个数组去取用户点了哪一项。
   */
  private showBookActions(book: Book): void {
    const actions: string[] = ['开始阅读'];
    /**
     * ⚠️ 「移入分组」只在**已有分组**时出现。
     *
     * 一个分组都没有时，点它只能弹一个"还没有分组"的空菜单 —— 那是死路。
     * 用户要建组应该走标题行的「＋分组」。
     * 判据：**菜单项要么能用，要么不显示**，不要放一个只会报错的入口。
     */
    const canGroup: boolean = this.state.groups.length > 0;
    if (canGroup) {
      actions.push('移入分组');
    }
    actions.push('换编码（正文乱码时用）');
    actions.push('从书架移除');

    const buttons: promptAction.Button[] = [];
    for (const action of actions) {
      buttons.push({
        text: action,
        // 危险项单独上色，其余中性
        color: action === '从书架移除' ? AppColorLiteral.danger : AppColorLiteral.textPrimary
      });
    }

    this.getUIContext().getPromptAction().showActionMenu({
      title: book.title,
      buttons: buttons as [promptAction.Button, promptAction.Button?, promptAction.Button?,
        promptAction.Button?, promptAction.Button?, promptAction.Button?]
    }).then(async (result) => {
      const picked: string = actions[result.index];
      if (picked === undefined) {
        return;
      }
      if (picked === '开始阅读') {
        this.openReader(book);
      } else if (picked === '移入分组') {
        this.showGroupPicker(book);
      } else if (picked === '换编码（正文乱码时用）') {
        await this.showEncodingPicker(book);
      } else if (picked === '从书架移除') {
        await this.vm.removeBook(book.id);
        this.toast('已移出书架');
      }
    }).catch(() => {
      // 用户取消
    });
  }

  /**
   * 单本书 → 选一个分组放进去。
   *
   * ⚠️ 列出全部分组 **+「未分组」**：
   * 「未分组」是"移出当前分组"的唯一入口，不给它用户就无法把书挪出来
   * （只能靠删掉整个分组，那会连带影响别的书）。
   *
   * ⚠️ 当前所在的分组标上「（当前）」：让用户知道点了会不会有变化。
   * 菜单最多六项，分组超过五个时截断并提示 —— 想一次挑很多本走
   * 「移入分组」页的批量入口（见 `openGroupPickerForTarget`）。
   */
  private showGroupPicker(book: Book): void {
    const groups: BookGroup[] = this.state.groups;
    /**
     * ⚠️ 上限是 **5** 而不是 6，因为「未分组」也占一项：
     * `showActionMenu` 最多只接受 **6 个按钮**（类型就是六元组），
     * 写成 6 就会拼出 7 项 —— 超出的部分会被系统丢弃或直接报错，
     * 表现是"最后那个分组点了没反应"。
     */
    const maxItems: number = 5;
    const shown: BookGroup[] = groups.slice(0, maxItems);

    const labels: string[] = [];
    const ids: number[] = [];
    // 「未分组」永远排第一：它最常用（把书从某个组里拿出来）
    labels.push(book.groupId === null ? '未分组（当前）' : '未分组');
    ids.push(-1);
    for (const group of shown) {
      const isCurrent: boolean = book.groupId === group.id;
      labels.push(isCurrent ? `${group.name}（当前）` : group.name);
      ids.push(group.id);
    }

    const buttons: promptAction.Button[] = [];
    for (const label of labels) {
      buttons.push({ text: label, color: AppColorLiteral.textPrimary });
    }

    const truncated: boolean = groups.length > shown.length;
    const title: string = truncated
      ? `${book.title}\n分组较多，仅显示前 ${shown.length} 个`
      : book.title;

    this.getUIContext().getPromptAction().showActionMenu({
      title: title,
      buttons: buttons as [promptAction.Button, promptAction.Button?, promptAction.Button?,
        promptAction.Button?, promptAction.Button?, promptAction.Button?]
    }).then(async (result) => {
      const groupId: number = ids[result.index];
      if (groupId === undefined) {
        return;
      }
      /**
       * ⚠️ 选了"当前所在的分组"就直接返回，不做无意义的写库 + 刷新：
       * 那会闪一下列表，用户还以为发生了什么。
       */
      const targetId: number | null = groupId < 0 ? null : groupId;
      if (targetId === book.groupId) {
        return;
      }
      await this.vm.moveToGroup(book.id, targetId);
      if (targetId === null) {
        this.toast('已移出分组');
      } else {
        this.toast('已移入分组');
      }
    }).catch(() => {
      // 用户取消
    });
  }

  /**
   * 打开「批量加入分组」页：**从已导入的书里勾选**，一次放进某个分组。
   *
   * ⚠️ 与 `showGroupPicker`（单本）的分工：
   *  - 单本 → 长按某本书，把它放进某个组；
   *  - 批量 → 从分组那一行进入，一次给一个组挑很多本书。
   * 两条路都需要：前者是日常整理，后者是"新建了一个组，把相关的书一次放进去"。
   */
  private openGroupPickerForTarget(groupId: number, groupName: string): void {
    const param: RouteParam = new RouteParam();
    param.groupId = groupId;
    /**
     * ⚠️ 名字随路由一起传（见 `RouteParam.groupName` 的说明）：
     * 目标页自己去查是异步的，首帧会先用默认值渲染标题，
     * 而普通成员赋值不触发重绘 —— 标题就永远停在错的名字上。
     */
    param.groupName = groupName;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.GROUP_PICKER_PAGE, params: param })
      .catch(() => {
        this.toast(`打开书籍选择页失败（目标：${groupName}）`);
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
      /**
       * ⚠️ 下标必须**显式校验**，不能只靠"取出来是 undefined 再判断"。
       *
       * 用户点弹窗外部取消时 `index` 是 `-1`；而菜单项数量、系统实际渲染的
       * 项数、`options` 数组长度三者并不保证一致（选项是数据、按钮是元组类型）。
       * 早先的写法把越界值继续往下传，最终会走到
       * `new util.StringDecoder(undefined)` 抛异常 —— 那是在 try 之外的下游，
       * 直接白屏。
       *
       * 判据：**外部系统返回的下标，使用前一律做边界检查**，
       * 不要假定它一定落在自己的数组范围内。
       */
      const pickedIndex: number = result.index;
      if (pickedIndex < 0 || pickedIndex >= options.length) {
        return;
      }
      const picked: string = options[pickedIndex];
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
        /**
         * ⚠️ 重解析成功不代表编码选对了：若章数依然极少，说明这个编码也不对，
         * 必须**明确告警**而不是轻描淡写地说"完成" ——
         * 用户会立刻点进阅读页，而那本书的单章过大、会白屏假死。
         * 告警只弹一次（读后即清），避免每次刷新书架都重复打扰。
         */
        if (this.state.reparseSuspicious) {
          this.state.reparseSuspicious = false;
          this.getUIContext().getPromptAction().showToast({
            message: `按 ${picked} 只解析出很少的章节，编码可能仍不正确，建议再换一个编码试试`,
            duration: 4000
          });
        } else {
          this.toast('重新解析完成，进阅读页确认');
        }
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
   * 长按分组条目 → 分组操作菜单。
   *
   * ⚠️ 它与分组详情页右上角的「更多」菜单**职责不同，都要保留**：
   *  - 本菜单（首页长按）= 不进入分组就能做的快捷操作；
   *  - 详情页的「更多」= 打开分组后的操作，多一项「编辑分组」（管理组内书籍）。
   *
   * ⚠️ 首页这里**不放「编辑分组」**：那是"管理组内的书"，
   * 而此刻用户还没打开这个组、看不到里面有什么 —— 让他先进去再编辑更合理。
   *
   * ⚠️ 文案与下标由同一个数组推导（设计文档第 28 条）。
   */
  private showGroupActions(groupId: number, name: string): void {
    const actions: string[] = ['打开分组', '加入书籍', '重命名', '解散分组'];

    const buttons: promptAction.Button[] = [];
    for (const action of actions) {
      buttons.push({
        text: action,
        color: action === '解散分组' ? AppColorLiteral.danger : AppColorLiteral.textPrimary
      });
    }

    this.getUIContext().getPromptAction().showActionMenu({
      title: `分组「${name}」`,
      buttons: buttons as [promptAction.Button, promptAction.Button?, promptAction.Button?,
        promptAction.Button?, promptAction.Button?, promptAction.Button?]
    }).then(async (result) => {
      const picked: string = actions[result.index];
      if (picked === undefined) {
        return;
      }
      if (picked === '打开分组') {
        this.openGroupDetailById(groupId, name);
      } else if (picked === '加入书籍') {
        this.openGroupPickerForTarget(groupId, name);
      } else if (picked === '重命名') {
        this.openRenameGroupDialog(groupId, name);
      } else if (picked === '解散分组') {
        await this.confirmDeleteGroup(groupId, name);
      }
    }).catch(() => {
      // 用户取消
    });
  }

  /**
   * 按 id 打开分组详情（长按菜单用）。
   *
   * ⚠️ 与 `openGroupDetail(group)` 是同一个动作的两个入口：
   * 一个手上是 `BookGroup` 对象、一个只有 id 与名字。
   * 不合并是因为详情页只需要 id + 名字两个值，
   * 为它去查一次 `BookGroup` 是多余的 IO。
   */
  private openGroupDetailById(groupId: number, name: string): void {
    const param: RouteParam = new RouteParam();
    param.groupId = groupId;
    param.groupName = name;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.GROUP_DETAIL_PAGE, params: param })
      .catch(() => {
        this.toast('打开分组失败');
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
