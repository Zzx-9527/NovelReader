import { AppTheme, ReaderTheme } from '../../common/theme/AppTheme';
import { AppFont } from '../../common/theme/AppFont';
import { ReaderSettings } from '../../model/ReaderSettings';
import { BookmarkDraft } from '../../viewmodels/ReaderState';
import { SettingsPanel } from './SettingsPanel';
import { ReaderTopBar } from './ReaderTopBar';
import { ReaderBottomBar } from './ReaderBottomBar';
import { BookmarkDialog } from './BookmarkDialog';

/**
 * 阅读页的**纯展示层**（从 `pages/ReaderPage.ets` 原样搬出）。
 *
 * ## 只搬这几块，判据是四条"不碰"
 *  - 不碰 `TextController` / `Scroller` / `SwiperController` 这类**挂在节点上**的控制器；
 *  - 不碰 `Text.selection()` / `copyOption` / `editMenuOptions` 这类**构建期**绑定的选中态；
 *  - 不碰 `gesture` / `parallelGesture` / `onTouch` / `hitTestBehavior` 这类**手势命中**链路；
 *  - 不承载滚动容器与正文。
 *
 * 满足这四条的块，输入只有「标量 + 回调 + 一个主题对象」，与现有
 * `ReaderTopBar` / `ReaderBottomBar` 完全同构 —— 那两个组件已经在用，
 * 说明"父组件状态变化 → 子组件重绘"这条路在本项目里是通的。
 *
 * ⚠️ 正文（滚动 / 分页 / 平移）**不在这里**，也**不要**搬进来：
 * 那些块手里握着上面四类东西，搬进子组件后编译器不会报错，
 * 但运行时的刷新与手势链路会变（本项目实测过），属于架构改动，不是拆分。
 */

/**
 * **常驻底栏**：左=当前章节名，右=全书阅读进度。
 *
 * 与点击中间弹出的菜单底栏（`ReaderBottomBar`）是两回事：
 *  - 本栏**永远可见**，提供"我在哪一章、读了百分之多少"；
 *  - 菜单底栏只在呼出菜单时出现，负责**操作**（进度条拖动、上下章、设置）。
 *
 * ⚠️ 本栏**不绑任何手势**：它只是"告知"。翻页层铺满全屏、会盖住这条区域的触摸 ——
 * 这是**有意为之**：用户点到屏幕最底部时期望的是翻页，而不是点到一条不可交互的信息条。
 */
@Component
export struct ReaderFooterBar {
  /** 当前章节名。父组件的 `headingText()` 是方法，所以由父传入**值** */
  @Prop chapterTitle: string = '';
  /** 页码（如 `5/16`）；scroll 模式为空串，此时右侧只显示百分比 */
  @Prop pageText: string = '';
  /** 全书百分比文案（如 `97.1%`） */
  @Prop progressText: string = '';
  /** 阅读页配色：必须 `@Prop`，否则切主题后这条栏还是旧色 */
  @Prop theme: ReaderTheme = new ReaderTheme();
  /** 底部安全区（手势条）高度，vp */
  @Prop safeAreaBottom: number = 0;
  /**
   * 本栏**总高**（= 文字区 + 安全区）。
   *
   * ⚠️ 由父组件算好传进来（父的 `footerTotalHeight()`），不在这里重算：
   * 菜单栏要按**同一个值**上移/覆盖，两处各算一次迟早对不上，
   * 表现为"菜单弹出时两栏重叠或留缝"。
   */
  @Prop totalHeight: number = 0;

  build() {
    Column() {
      /**
       * 与正文的分隔线。
       *
       * 用 `theme.secondary` 而非 `AppColor.divider`：本栏属于阅读页，
       * 配色必须跟随阅读主题（羊皮纸/夜间/护眼）。
       * ⚠️ 30% 的发丝线而不是满强度：满强度在浅色主题下比正文里的标点还显眼，
       * 读起来像给正文加了个下边框。
       */
      Row()
        .width('100%')
        .height(AppTheme.HAIRLINE)
        .backgroundColor(this.theme.secondary)
        .opacity(AppTheme.READER_RULE_ALPHA)

      Row() {
        // 左：章节名。长标题截断，完整标题在目录里能看全
        Text(this.chapterTitle)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        /**
         * 右：**页码 + 全书进度**。
         * ⚠️ 两段都走 `AppFont.TABULAR`（等宽数字）：翻页时页码与百分比都在变，
         * 比例数字下每一位宽度不同，整段会左右抖动 —— 而它紧贴屏幕右下角，很显眼。
         */
        if (this.pageText.length > 0) {
          Text(this.pageText)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(this.theme.secondary)
            .fontFeature(AppFont.TABULAR)
            .margin({ left: AppTheme.GAP_S })
        }

        Text(this.progressText)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
          .fontFeature(AppFont.TABULAR)
          .margin({ left: AppTheme.GAP_S })
      }
      .width('100%')
      /**
       * 文字行用 `layoutWeight(1)` 吃掉"总高 − 分隔线 − 手势条占位"的余量。
       * ⚠️ 不要写固定 `height(READER_FOOTER_HEIGHT)`：那样会比总高多出分隔线那 1vp。
       */
      .layoutWeight(1)
      .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
      .alignItems(VerticalAlign.Center)

      /** 手势条避让占位：把这块空间**显式**留出来，与 `footerTotalHeight()` 严格对应 */
      if (this.safeAreaBottom > 0) {
        Row()
          .width('100%')
          .height(this.safeAreaBottom)
      }
    }
    .width('100%')
    .height(this.totalHeight)
    // ⚠️ 背景用**不透明**的 `theme.bg`，不用半透明的 `theme.barBg`：
    // 本栏是**常驻**的，半透明会让正文文字从它后面透出来，看起来像渲染错误。
    .backgroundColor(this.theme.bg)
  }
}

/**
 * 章节标题（分页模式：只出现在本章第一页）。
 *
 * ⚠️ 它就是"正文第一行"，读过去随正文翻走，不是常驻页眉。
 *
 * ⚠️ 它**不改变高度**是硬约束：`headingHeight()` 是把"行高 + 上下内边距"
 * 算好交给分页服务的（首页要给标题让位）。所以题花线只能叠在**既有的
 * 12vp 下内边距之内**（`Stack` + `Alignment.BottomStart`），
 * 一旦它真的占了新的一行，就必须同步改 `headingHeight()`；
 * 漏改的症状是"首页最后一行正文被裁掉"，而且**不报错**。
 */
@Component
export struct ReaderChapterHeading {
  @Prop text: string = '';
  @Prop theme: ReaderTheme = new ReaderTheme();
  /** 阅读设置：字号与字体必须与分页测量同源，所以读的是父组件的同一份快照 */
  @Prop settings: ReaderSettings = new ReaderSettings();
  /** 标题行高：由父组件的 `headingLineHeight()` 算好传入，保证与分页口径一致 */
  @Prop lineHeight: number = 0;

  build() {
    if (this.text.length > 0) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Text(this.text)
          .fontSize(this.settings.fontSize + AppTheme.SIZE_STEP)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.text)
          // 字体必须与分页测量同源（见 ReaderSettings.resolveFontFamily）
          .fontFamily(ReaderSettings.resolveFontFamily(this.settings.fontFamily))
          /** ⚠️ 只加字距不动行高：装饰只能改**宽度方向** */
          .letterSpacing(AppTheme.TRACK_CHAPTER)
          .lineHeight(this.lineHeight)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ top: AppTheme.GAP_S, bottom: AppTheme.GAP_M })

        /** 题花线：全书**唯一**的装饰元素（左对齐、同起点，不是分隔符） */
        Row()
          .width(AppTheme.READER_RULE_W)
          .height(AppTheme.HAIRLINE)
          .backgroundColor(this.theme.secondary)
          .opacity(0.55)
          .margin({ bottom: 6 })
      }
      .width('100%')
    }
  }
}

/**
 * 设置面板的内容壳（`bindSheet` 只接受 `@Builder` 引用，
 * 所以页面保留一个三行的 builder，内容在这里）。
 */
@Component
export struct ReaderSettingsSheet {
  @Prop settings: ReaderSettings = new ReaderSettings();
  @Prop theme: ReaderTheme = new ReaderTheme();
  @Prop safeAreaBottom: number = 0;
  onChange: (next: ReaderSettings) => void = () => {};
  onClose: () => void = () => {};

  build() {
    SettingsPanel({
      settings: this.settings,
      theme: this.theme,
      safeAreaBottom: this.safeAreaBottom,
      onChange: (next: ReaderSettings) => {
        this.onChange(next);
      },
      onClose: () => {
        this.onClose();
      }
    })
  }
}

/**
 * 加书签 / 写笔记的弹窗层（最顶层，压在设置面板之上）。
 *
 * ⚠️ 放在**最顶**：它由长按选中触发，可能发生在菜单已弹出时。
 * ⚠️ **不给这层加 padding**：弹窗内部自带全屏遮罩（`Stack` 铺满 + `AppColor.mask`），
 * 加了顶部让位反而会让遮罩盖不住状态栏、在最上面留出一条缝。
 */
@Component
export struct ReaderBookmarkLayer {
  @Prop draft: BookmarkDraft = new BookmarkDraft();
  @Prop theme: ReaderTheme = new ReaderTheme();
  /** 'bookmark' 或 'note'：决定标题、备注提示语与"备注是否必填" */
  @Prop mode: string = 'bookmark';
  onSave: (note: string) => void = () => {};
  onCancel: () => void = () => {};

  build() {
    BookmarkDialog({
      draft: this.draft,
      theme: this.theme,
      mode: this.mode,
      onSave: (note: string) => {
        this.onSave(note);
      },
      onCancel: () => {
        this.onCancel();
      }
    })
  }
}

/**
 * 菜单层：顶栏 + 中间透明点击区 + 底栏（只在菜单显示时出现，且位于翻页层之上）。
 *
 * ⚠️ 四条约束都踩过坑，改结构前先读：
 *  1. 本层**只在菜单显示时存在**（由父组件的 `if` 控制），否则它会盖在翻页层之上
 *     把点击截走，导致"菜单弹出后无法收回"；
 *  2. 中间**不加蒙层**（用户明确要求）：菜单模式要能看清正文，顶栏/底栏夹着正文，
 *     中间保持透明；蒙层只用于设置面板；
 *  3. 顶栏从上方滑下、底栏从下方升起，动画必须挂在**各自的栏**上 ——
 *     挂在整层会让顶栏跟着底栏一起从下往上滑，方向完全不对；
 *  4. 本层只让出**顶部**安全区，底部**不让位**：菜单栏要覆盖常驻底栏，
 *     底部安全区由 `ReaderBottomBar` 自己用 `safeAreaBottom` 涂满。
 */
@Component
export struct ReaderMenuLayer {
  /** 顶栏中间显示**书名**（用户要求），不是章节名 */
  @Prop title: string = '';
  @Prop theme: ReaderTheme = new ReaderTheme();
  /** 全书进度 0~1，驱动菜单底栏的进度条 */
  @Prop percent: number = 0;
  @Prop hasPrev: boolean = false;
  @Prop hasNext: boolean = false;
  @Prop safeAreaBottom: number = 0;
  @Prop safeAreaTop: number = 0;
  /** 应用级夜间态：只影响菜单底栏"夜间"入口的高亮，与正文背景无关 */
  @Prop appDarkMode: boolean = false;

  onBack: () => void = () => {};
  onRefresh: () => void = () => {};
  onHideMenu: () => void = () => {};
  onJump: (percent: number) => void = () => {};
  onPrevChapter: () => void = () => {};
  onNextChapter: () => void = () => {};
  onOpenCatalog: () => void = () => {};
  onToggleNight: () => void = () => {};
  onOpenSettings: () => void = () => {};

  build() {
    Column() {
      ReaderTopBar({
        title: this.title,
        theme: this.theme,
        onBack: () => {
          this.onBack();
        },
        onRefresh: () => {
          this.onRefresh();
        }
      })
      /** 顶栏从**屏幕上方**滑下（`y` 为负 = 向上偏移，故起始位置在屏幕外） */
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.translate({ y: -AppTheme.TOP_BAR_HEIGHT }).combine(TransitionEffect.opacity(0)),
        TransitionEffect.translate({ y: -AppTheme.TOP_BAR_HEIGHT }).combine(TransitionEffect.opacity(0))
      ).animation({ duration: 180, curve: Curve.FastOutSlowIn }))

      // 菜单显示时，点中间空白处收回菜单（用 hideMenu 而不是 toggleMenu：收起是幂等的）
      Blank()
        .onClick(() => {
          this.onHideMenu();
        })

      ReaderBottomBar({
        theme: this.theme,
        percent: this.percent,
        hasPrev: this.hasPrev,
        hasNext: this.hasNext,
        safeAreaBottom: this.safeAreaBottom,
        appDarkMode: this.appDarkMode,
        onJump: (percent: number) => {
          this.onJump(percent);
        },
        onPrevChapter: () => {
          this.onPrevChapter();
        },
        onNextChapter: () => {
          this.onNextChapter();
        },
        onOpenCatalog: () => {
          this.onOpenCatalog();
        },
        onToggleNight: () => {
          this.onToggleNight();
        },
        onOpenSettings: () => {
          this.onOpenSettings();
        }
      })
      /** 底栏从**屏幕下方**滑入：起始位置下移 80vp，视觉上就是"从底边升起、盖住常驻栏" */
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.translate({ y: 80 }).combine(TransitionEffect.opacity(0)),
        TransitionEffect.translate({ y: 80 }).combine(TransitionEffect.opacity(0))
      ).animation({ duration: 180, curve: Curve.FastOutSlowIn }))
    }
    .width('100%')
    .height('100%')
    /**
     * ⚠️ 只让出**顶部**安全区；底部**不让位** —— 菜单栏要盖住常驻底栏。
     * 早期让菜单层整体上移 `footerTotalHeight()`，结果是两条栏上下堆叠、观感很乱。
     *
     * ⚠️ 顶部必须写在**同一次** `padding()` 里：ArkUI 里同一组件多次 `.padding()`
     * 是后者覆盖前者、不是叠加（本项目实测踩过）。
     */
    .padding({ top: this.safeAreaTop })
  }
}
