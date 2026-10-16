import { Book } from '../model/Book';
import { RouteName, RouteParam } from '../model/RouteParam';
import { AppConstants } from '../common/constants/AppConstants';
import { BookRepository } from '../data/repository/BookRepository';
import { AnnotationRepository } from '../data/repository/AnnotationRepository';
import { GroupRepository } from '../data/repository/GroupRepository';
import { ChapterRepository } from '../data/repository/ChapterRepository';
import { ImportService, ImportResult, ImportOutcome } from '../data/service/ImportService';
import { AppColor, AppTheme } from '../common/theme/AppTheme';
import { AppFont } from '../common/theme/AppFont';
import { Logger } from '../common/utils/Logger';
import { FileUtil } from '../common/utils/FileUtil';
import { DateUtil } from '../common/utils/DateUtil';
import { Encodings } from '../common/utils/EncodingDetector';
import { LoadingView } from '../views/common/LoadingView';
import { ErrorView } from '../views/common/ErrorView';
import { BookCover } from '../views/bookshelf/BookCover';
import { TextInputDialog } from '../views/common/TextInputDialog';
import { ThemeMenu } from '../views/common/ThemeMenu';
import { ThemeConfirm } from '../views/common/ThemeConfirm';

/**
 * 标题左右各留的安全间距（vp）。
 *
 * ⚠️ 与 `GroupDetailPage.TITLE_GUTTER` 同一个理由与量级：
 * 标题铺满整宽后要自己居中，长书名会伸到左右控件下面被压住。
 */
const TITLE_GUTTER: number = 72;

/**
 * 书籍详情页（书架长按书籍 →「书籍详情」）。
 *
 * 版面（自上而下）：
 * ```
 * ‹ 返回         书籍详情          ⋮
 * ──────────────────────────────────
 * [封面]  书名
 *         作者
 *         ▓▓▓▓░░░░ 45.2%
 * ──────────────────────────────────
 * 继续「第 12 章 ……」            ›   ← 有进度才显示
 * ──────────────────────────────────
 * 章节数        128 章
 * 总字数        36.2 万
 * 文件大小      2.4 MB
 * 编码          GB18030
 * 收录时间      2024-05-01
 * 最近阅读      3 小时前
 * 书签/划线/笔记  3 / 5 / 1
 * ──────────────────────────────────
 * ```
 *
 * ## 职责边界
 *
 * 本页是"一本书的档案 + 操作入口"，**不做**阅读（那是阅读页的事）、
 * **不做**章节列表（那是目录页的事）。所有写操作（重命名/换编码/移除）
 * 复用书架既有的服务与方法 —— 不在详情页另写一套业务逻辑。
 *
 * ⚠️ 配色走 `AppColor`（跟随系统深浅色），与书架一致 ——
 * 本页属于书架流程，不是阅读页内部（那边才用 `ReaderTheme`）。
 */
@Entry
@Component
struct BookDetailPage {
  /** 安全区高度（vp），沉浸式全屏的配套让位 */
  @StorageProp('safeAreaTop') safeAreaTop: number = 0;
  @StorageProp('safeAreaBottom') safeAreaBottom: number = 0;

  @State private book: Book | null = null;
  @State private groupName: string = '';
  @State private loading: boolean = true;
  @State private error: string = '';
  /** 标注计数（书签/划线/笔记），加载完成后填充；-1 表示还没加载到 */
  @State private bookmarkCount: number = -1;
  @State private highlightCount: number = -1;
  @State private noteCount: number = -1;

  // ── 弹窗挂载状态（与 GroupDetailPage 同一套做法）──────────
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
  /** 重命名弹窗 */
  @State private renameVisible: boolean = false;
  @State private renameInitial: string = '';

  private bookId: number = 0;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as RouteParam | null;
    if (params !== null && params !== undefined) {
      this.bookId = params.bookId;
    }
    if (this.bookId <= 0) {
      this.error = '缺少书籍参数';
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
   * 进度、最近阅读时间、"继续阅读"那行都可能变了。
   */
  onPageShow(): void {
    if (this.bookId > 0) {
      this.loadAll().catch(() => {
      });
    }
  }

  /** 加载书籍与配套数据（分组名 + 三类标注计数） */
  private async loadAll(): Promise<void> {
    try {
      const book: Book | null = await BookRepository.getById(this.bookId);
      if (book === null) {
        this.error = '这本书已不存在（可能已被移除）';
        this.loading = false;
        return;
      }
      this.book = book;
      // 分组名（未分组时留空）
      if (book.groupId !== null) {
        const group = await GroupRepository.getById(book.groupId);
        this.groupName = group !== null ? group.name : '';
      } else {
        this.groupName = '';
      }
      // 三类标注计数并行发查（各自独立，一条失败不影响其它）
      this.loadCounts().catch(() => {
      });
      this.error = '';
    } catch (e) {
      this.error = `加载失败：${Logger.errText(e as Object)}`;
    } finally {
      this.loading = false;
    }
  }

  /** 加载三类标注计数（失败静默：计数缺失只显示"-"，不影响页面主体） */
  private async loadCounts(): Promise<void> {
    try {
      this.bookmarkCount = await AnnotationRepository.countByBook(
        this.bookId, AppConstants.ANNOTATION_BOOKMARK);
    } catch (e) {
      this.bookmarkCount = -1;
    }
    try {
      this.highlightCount = await AnnotationRepository.countByBook(
        this.bookId, AppConstants.ANNOTATION_HIGHLIGHT);
    } catch (e) {
      this.highlightCount = -1;
    }
    try {
      this.noteCount = await AnnotationRepository.countByBook(
        this.bookId, AppConstants.ANNOTATION_NOTE);
    } catch (e) {
      this.noteCount = -1;
    }
  }

  // ------------------------------------------------------------ 操作

  /** 开始阅读（沿用全书进度，由阅读页自己恢复） */
  private openReader(): void {
    const param: RouteParam = new RouteParam();
    param.bookId = this.bookId;
    param.from = RouteName.BOOK_SHELF;
    this.getUIContext().getRouter()
      .pushUrl({ url: RouteName.READER_PAGE, params: param })
      .catch(() => {
        this.toast('打开阅读页失败');
      });
  }

  /** 右上角「更多」菜单（重命名 / 换编码 / 从书架移除） */
  private showMoreMenu(): void {
    const book: Book | null = this.book;
    if (book === null) {
      return;
    }
    const actions: string[] = ['重命名', '换编码（正文乱码时用）', '从书架移除'];
    this.openThemeMenu(book.title, actions, `${actions.length - 1}`, (index: number) => {
      const picked: string = actions[index];
      if (picked === undefined) {
        return;
      }
      if (picked === '重命名') {
        this.renameInitial = book.title;
        this.renameVisible = true;
      } else if (picked === '换编码（正文乱码时用）') {
        this.showEncodingPicker();
      } else if (picked === '从书架移除') {
        this.confirmRemove();
      }
    });
  }

  /**
   * 换编码重解析（与书架长按菜单同一套流程与文案）。
   *
   * ⚠️ 重分章会级联删除该书全部书签/笔记 —— 必须二次确认，
   * 文案与 `BookShelfPage` 保持一致（同一件事两套说法会让用户困惑）。
   */
  private async showEncodingPicker(): Promise<void> {
    const book: Book | null = this.book;
    if (book === null) {
      return;
    }
    const current: string = book.encoding;
    const options: string[] = [
      Encodings.UTF8, Encodings.GB18030, Encodings.GBK,
      Encodings.BIG5, Encodings.UTF16LE, Encodings.UTF16BE
    ];
    const labels: string[] = [];
    let currentIndex: number = -1;
    for (let i = 0; i < options.length; i++) {
      labels.push(options[i] === current ? `${options[i]}（当前）` : options[i]);
      if (options[i] === current) {
        currentIndex = i;
      }
    }
    this.openThemeMenu('选择编码（重新分章）', labels, '', (index: number) => {
      if (index < 0 || index >= options.length) {
        return;
      }
      const picked: string = options[index];
      if (picked === undefined || picked === current) {
        return;
      }
      // 有标注时先确认代价（与书架同一文案）；没有标注直接执行
      this.confirmReparse(picked);
    });
  }

  /** 换编码的二次确认（查受影响标注数；无标注不打扰） */
  private confirmReparse(encoding: string): void {
    BookShelfBridge.countAnnotationsImpacted(this.bookId).then((impacted: number) => {
      if (impacted > 0) {
        this.confirmTitle = '确认重新分章？';
        this.confirmMessage = `这本书的 ${impacted} 条书签/笔记会一并被删除，且无法恢复。`;
        this.confirmText = '删除并重新分章';
        this.confirmDanger = true;
        this.confirmOnYes = () => {
          this.runReparse(encoding);
        };
        this.confirmVisible = true;
        return;
      }
      this.runReparse(encoding);
    }).catch(() => {
      // 查不到标注数时保守处理：按"无标注"走（与书架行为一致）
      this.runReparse(encoding);
    });
  }

  /** 执行重解析（复用 ImportService，与书架同一条路） */
  private runReparse(encoding: string): void {
    this.toast(`正在按 ${encoding} 重新解析…`);
    BookShelfBridge.reparse(this.bookId, encoding).then((suspicious: boolean) => {
      if (suspicious) {
        this.toast(`按 ${encoding} 只解析出很少的章节，编码可能仍不正确，建议再换一个编码试试`);
      } else {
        this.toast('重新解析完成');
      }
      this.loadAll().catch(() => {
      });
    }).catch((e: Object) => {
      // 把服务层的具体原因（如"文件丢失"）带出来，而不是一律说"失败"
      const msg: string = e instanceof Error && e.message.length > 0 ? e.message : '重新解析失败';
      this.toast(msg);
    });
  }

  /** 从书架移除（二次确认 + 返回书架） */
  private confirmRemove(): void {
    const book: Book | null = this.book;
    if (book === null) {
      return;
    }
    this.confirmTitle = `从书架移除《${book.title}》？`;
    this.confirmMessage = '这本书会从书架消失（阅读进度与书签笔记保留在库中，书源文件也不删）。';
    this.confirmText = '移除';
    this.confirmDanger = true;
    this.confirmOnYes = () => {
      BookRepository.softDelete(this.bookId).then(() => {
        this.toast('已从书架移除');
        this.getUIContext().getRouter().back();
      }).catch(() => {
        this.toast('移除失败');
      });
    };
    this.confirmVisible = true;
  }

  /** 提交重命名（书名 + 作者可一起改） */
  private submitRename(value: string): void {
    const book: Book | null = this.book;
    const title: string = value.trim();
    if (book === null || title.length === 0 || title === book.title) {
      this.renameVisible = false;
      return;
    }
    BookRepository.rename(book.id, title, book.author).then(() => {
      this.renameVisible = false;
      this.toast('已重命名');
      this.loadAll().catch(() => {
      });
    }).catch(() => {
      this.toast('重命名失败');
    });
  }

  // ------------------------------------------------------------ 弹窗基建（与 GroupDetailPage 同一套）

  private openThemeMenu(title: string, options: string[], danger: string,
    onPick: (index: number) => void): void {
    this.menuTitle = title;
    this.menuOptions = options;
    this.menuDanger = danger;
    this.menuOnPick = onPick;
    this.menuVisible = true;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  // ------------------------------------------------------------ 展示辅助

  /** 进度百分比文案（无进度返回空串，调用方据此隐藏进度条） */
  private percentText(): string {
    const book: Book | null = this.book;
    if (book === null || book.hasNoProgress()) {
      return '';
    }
    const p: number = book.progressPercent < 0 ? 0
      : (book.progressPercent > 1 ? 1 : book.progressPercent);
    return `${(p * 100).toFixed(1)}%`;
  }

  /** 字数：万为单位保留一位小数（与统计页口径一致） */
  private wordCountText(): string {
    const book: Book | null = this.book;
    if (book === null) {
      return '-';
    }
    if (book.wordCount >= 10000) {
      return `${(book.wordCount / 10000).toFixed(1)} 万`;
    }
    return `${book.wordCount}`;
  }

  /** 固定格式的收录/日期文案 */
  private formatDate(timestamp: number): string {
    if (timestamp <= 0) {
      return '-';
    }
    const d = new Date(timestamp);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  /** 标注计数文案：-1（未加载/失败）显示"-" */
  private countText(count: number): string {
    return count >= 0 ? `${count}` : '-';
  }

  build() {
    Stack() {
      Column() {
        this.buildHeader()
        Divider().color(AppColor.divider)

        if (this.loading) {
          LoadingView({ message: '正在加载…' })
        } else if (this.error.length > 0 || this.book === null) {
          ErrorView({
            message: this.error.length > 0 ? this.error : '书籍不存在',
            hint: '返回书架看看这本书是否还在',
            actionText: '返回书架',
            onRetry: () => {
              this.getUIContext().getRouter().back();
            }
          })
        } else {
          this.buildBody()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.bgPage)

      // 重命名弹窗（最上层）
      if (this.renameVisible) {
        TextInputDialog({
          title: '重命名书籍',
          label: '输入新的书名',
          placeholder: '书名，最多 50 字',
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

      // 主题化动作菜单
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

      // 主题化确认弹窗
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
    .backgroundColor(AppColor.bgPage)
    .padding({ top: this.safeAreaTop, bottom: this.safeAreaBottom })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 头部：左返回、中标题、右「更多」（与 GroupDetailPage 同一套布局） */
  @Builder
  buildHeader() {
    Stack({ alignContent: Alignment.Center }) {
      Text('书籍详情')
        .fontSize(AppTheme.FONT_SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .width('100%')

      Row() {
        Text('‹ 返回')
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppColor.textPrimary)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Blank()

        Image($r('app.media.more'))
          .width(20)
          .height(20)
          .objectFit(ImageFit.Contain)
          .fillColor(AppColor.textPrimary)
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .onClick(() => {
            this.showMoreMenu();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height(AppTheme.TOP_BAR_HEIGHT)
  }

  /** 主体：封面头部 + 继续阅读 + 信息表 */
  @Builder
  buildBody() {
    Scroll() {
      Column() {
        this.buildBookHead()
        this.buildContinueRow()
        this.buildInfoCard()
      }
      .width('100%')
      .padding(AppTheme.PAGE_PADDING)
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
  }

  /** 封面 + 书名/作者/分组 + 进度条 */
  @Builder
  buildBookHead() {
    Row({ space: AppTheme.GAP_M }) {
      /**
       * ⚠️ `BookCover` **不决定自己的尺寸**（一律 100%×100%，见其类注释），
       * 必须由外层容器给尺寸 —— 直接塞进 `Row` 会撑满整行。
       * 详情页的封面取 96×128（3:4，与书架封面同比例、放大约一倍）：
       * 本页一屏只有一个封面，它是"这本书"的视觉锚点，值得比列表行（48×64）大。
       */
      Column() {
        BookCover({
          label: this.book !== null
            ? (this.book.title.length > 0 ? this.book.title.substring(0, 1) : '书')
            : '书',
          percent: this.book !== null ? this.book.progressPercent : 0
        })
      }
      .width(96)
      .height(128)
      .borderRadius(AppTheme.ITEM_RADIUS)
      .clip(true)

      Column({ space: AppTheme.GAP_S }) {
        Text(this.book !== null ? this.book.title : '')
          .fontSize(AppTheme.FONT_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.book !== null && this.book.author.length > 0) {
          Text(this.book.author)
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(AppColor.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        if (this.groupName.length > 0) {
          Text(`分组：${this.groupName}`)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        // 进度条（有进度才显示；无进度显示"未开始阅读"）
        if (this.percentText().length > 0) {
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .height(AppTheme.RAIL_H)
              .borderRadius(AppTheme.RAIL_H / 2)
              .backgroundColor(AppColor.divider)
              .width('100%')

            Row()
              .height(AppTheme.RAIL_H)
              .borderRadius(AppTheme.RAIL_H / 2)
              .backgroundColor(AppColor.accent)
              .width(this.fillWidth())
          }
          .width('100%')

          Text(`已读 ${this.percentText()}`)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
            .fontFeature(AppFont.TABULAR)
        } else {
          Text('未开始阅读')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: AppTheme.GAP_M, bottom: AppTheme.GAP_L })
    .alignItems(VerticalAlign.Top)
  }

  /** 进度条填充宽度（与 BookCover 同一口径） */
  private fillWidth(): string {
    const book: Book | null = this.book;
    if (book === null) {
      return '0%';
    }
    const p: number = book.progressPercent < 0 ? 0
      : (book.progressPercent > 1 ? 1 : book.progressPercent);
    return `${(p * 100).toFixed(1)}%`;
  }

  /** 「继续阅读」行：显示上次读到的章节，点击直达 */
  @Builder
  buildContinueRow() {
    if (this.book !== null && !this.book.hasNoProgress()
      && this.book.lastChapterIndex >= 0
      && this.book.lastChapterIndex < this.book.totalChapters) {
      Row({ space: AppTheme.GAP_S }) {
        Column({ space: 2 }) {
          Text('继续阅读')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppColor.textHint)
          Text(`第 ${this.book.lastChapterIndex + 1} 章 / 共 ${this.book.totalChapters} 章`)
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(AppColor.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('›')
          .fontSize(AppTheme.FONT_TITLE)
          .fontColor(AppColor.textHint)
      }
      .width('100%')
      .padding(AppTheme.GAP_M)
      .borderRadius(AppTheme.CARD_RADIUS)
      .backgroundColor(AppColor.bgCard)
      .onClick(() => {
        this.openReader();
      })
    }
  }

  /** 信息卡：账目行样式（左标签右数值，发丝线分隔） */
  @Builder
  buildInfoCard() {
    Column() {
      this.infoRow('章节数', this.book !== null ? `${this.book.totalChapters} 章` : '-')
      this.infoRow('总字数', this.wordCountText())
      this.infoRow('文件大小', this.book !== null ? FileUtil.humanSize(this.book.fileSize) : '-')
      this.infoRow('编码', this.book !== null ? this.book.encoding : '-')
      this.infoRow('收录时间', this.book !== null ? this.formatDate(this.book.addedAt) : '-')
      this.infoRow('最近阅读',
        this.book !== null ? (DateUtil.humanize(this.book.lastReadAt).length > 0
          ? DateUtil.humanize(this.book.lastReadAt) : '从未') : '-')
      this.infoRow('书签 / 划线 / 笔记',
        `${this.countText(this.bookmarkCount)} / ${this.countText(this.highlightCount)} / ${this.countText(this.noteCount)}`)
    }
    .width('100%')
    .padding({ left: AppTheme.GAP_M, right: AppTheme.GAP_M })
    .borderRadius(AppTheme.CARD_RADIUS)
    .backgroundColor(AppColor.bgCard)
    .margin({ top: AppTheme.GAP_M })
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppColor.textSecondary)
        .layoutWeight(1)
      Text(value)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppColor.textPrimary)
        .fontFeature(AppFont.TABULAR)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .border({ width: { bottom: AppTheme.HAIRLINE }, color: AppColor.divider })
  }
}

/**
 * 书架桥接：详情页里"换编码重解析"复用书架同款服务调用序列，
 * 不自己 new BookShelfViewModel（那是页面级对象，持有整份书架状态）。
 *
 * ⚠️ 与 `BookShelfViewModel.reparseWithEncoding` 保持**同源**：
 * 那边改了解码/可疑告警逻辑，这里跟着改这一处。
 */
class BookShelfBridge {
  /** 统计重分章会删除多少条标注（与书架同一查询） */
  static async countAnnotationsImpacted(bookId: number): Promise<number> {
    return ChapterRepository.countAnnotationsImpacted(bookId);
  }

  /** 执行换编码重解析；返回结果是否可疑（章数极少 ⇒ 编码八成还是错的） */
  static async reparse(bookId: number, encoding: string): Promise<boolean> {
    const result: ImportResult = await ImportService.reparse(bookId, encoding);
    if (result.outcome !== ImportOutcome.SUCCESS) {
      throw new Error(result.error);
    }
    return result.suspicious;
  }
}
