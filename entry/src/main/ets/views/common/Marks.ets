import { AppColor, AppTheme } from '../../common/theme/AppTheme';

/**
 * 三个"画出来的"界面标记。
 *
 * ## 为什么不用图片资源
 *
 * 本项目全程**零图片依赖**（连封面都是文字占位），引一个图标就要多一份
 * `resources/base/media` 资源，还要维护深浅色两套 —— 而下面这三个标记
 * 全部由**圆角矩形与旋转的方框**构成，颜色直接取 `AppColor` 令牌，
 * 深浅模式自动跟随，不需要第二套资源。
 *
 * ## 为什么不用 `Path` / `Polyline` / SVG
 *
 * 它们当然更精确，但本项目**编译验证成本很高**，而这三个形状用
 * `Column` / `Row` / `Stack` + `.border()` + `.rotate()` 就能精确表达：
 * 圆角矩形是组件自带能力，"折角箭头"是"一个只带两条边的方框旋转 45°"
 * （这个构造的点位是**确定**的，不依赖字体，也不依赖路径解析）。
 *
 * ⚠️ 判据：**能用基础组件精确表达的几何，就不要引入路径/资源**。
 * 只有真正的曲线（弧、贝塞尔）才值得动 `Path`。
 */

/**
 * 空状态标记：三张叠放的纸页 + 一条点缀色书签带。
 *
 * 纵深靠**三段不透明度**（0.26 / 0.5 / 1）而不是三个灰阶颜色 ——
 * 这样它在浅色与深色下都成立，且不需要新增任何颜色令牌。
 *
 * ⚠️ 底层两张用 `bgPage` 填充：它等于所在页面的底色，
 * 于是"填充"在视觉上是透明的，只有那圈淡描边可见 ——
 * 这正是"叠放的纸"该有的样子。换成 `bgCard` 会在浅色页面上
 * 露出三块白方块，看起来像三张贴纸。
 */
@Component
export struct MarkEmpty {
  build() {
    Stack({ alignContent: Alignment.Center }) {
      /**
       * ⚠️ 三张纸页的偏移量必须是 **−6 / 0 / +6**，不能是 −12 / −6 / 0。
       *
       * `offset` 不参与布局，所以三张纸叠出来的**视觉外框**才是这一块真正占的地方。
       * 用 −12/−6/0 时外框整体向左上偏了半个步长（6vp），
       * 于是这个标记在它 92×92 的盒子里看起来是歪的 ——
       * 而它下面还跟着居中的标题和按钮，那点偏心会被三条居中线**放大**成"没对齐"。
       * 取对称的 ±6 之后，外框中心正好落在盒子中心（x: 17~75、y: 11~81，中心都是 46）。
       */
      Column()
        .width(46)
        .height(58)
        .borderRadius(4)
        .backgroundColor(AppColor.bgPage)
        .border({ width: AppTheme.HAIRLINE, color: AppColor.textHint })
        .opacity(0.26)
        .offset({ x: -6, y: -6 })

      // 第二张（对称的中点，不加偏移）
      Column()
        .width(46)
        .height(58)
        .borderRadius(4)
        .backgroundColor(AppColor.bgPage)
        .border({ width: AppTheme.HAIRLINE, color: AppColor.textHint })
        .opacity(0.5)
        .offset({ x: 0, y: 0 })

      /**
       * 第一张（最上、最右下、完全不透明）：正文线 + 书签带。
       *
       * ⚠️ 这一张是 `Stack` 而不是单节点，因为它上面要叠书签带。
       *
       * ⚠️ 书签带取 **18vp 高**，不是 22 —— 这个数字是被正文线逼出来的：
       * 三条正文线加两个 8vp 间距共 19vp，在 58vp 的纸页里垂直居中 ⇒
       * 它们占 y 19.5~38.5；书签带从顶边垂下，占 y 0~18。
       * 两者**纵向不相交**，所以书签带不需要为正文线让出水平空间、
       * 正文线也不必缩短。取 22 就会与第一条正文线叠在一起（22 > 19.5）。
       */
      Stack({ alignContent: Alignment.TopEnd }) {
        Column({ space: 8 }) {
          Row().width(28).height(AppTheme.HAIRLINE).backgroundColor(AppColor.textHint).opacity(0.45)
          Row().width(28).height(AppTheme.HAIRLINE).backgroundColor(AppColor.textHint).opacity(0.45)
          Row().width(17).height(AppTheme.HAIRLINE).backgroundColor(AppColor.textHint).opacity(0.45)
        }
        .width(46)
        .height(58)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(4)
        .backgroundColor(AppColor.bgPage)
        .border({ width: AppTheme.HAIRLINE, color: AppColor.textHint })

        // 书签带：点缀色唯一的去处。底端两角切圆，读作"垂下来的一条带子"
        Column()
          .width(9)
          .height(18)
          .backgroundColor(AppColor.accent)
          .borderRadius({ bottomLeft: 2, bottomRight: 2 })
          .margin({ right: 11 })
      }
      .width(46)
      .height(58)
      // 与最下那张对称：−6 / 0 / +6 三档，外框因此正落在 92×92 的中心
      .offset({ x: 6, y: 6 })
    }
    .width(AppTheme.MARK_SIZE)
    .height(AppTheme.MARK_SIZE)
  }
}

/**
 * 错误状态标记：一个描边圆 + 感叹号。
 *
 * ⚠️ 取代原来的 `Text('✗')`：那个字形的**大小、粗细、基线位置**都随字体变化，
 * 在换字体或换设备的机器上会明显不一样，而它恰恰是错误态的主视觉。
 * 圆是组件画的（尺寸确定），感叹号是 `!`（这个字符在任何字体里的画法都一致）。
 */
@Component
export struct MarkError {
  build() {
    Column() {
      Text('!')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.danger)
    }
    .width(30)
    .height(30)
    .borderRadius(15)
    .border({ width: 1.5, color: AppColor.danger })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}

/**
 * 列表项右侧的折角箭头。
 *
 * ⚠️ 取代文本字形 `›`：它的粗细与垂直位置同样随字体漂移，
 * 而"我的"页有四个行尾箭头，四个一起漂会比错误标记更显眼。
 *
 * 构造：一个 8×8 的方框，**只给上边与右边描边**，再顺时针旋转 45° ——
 * 于是那个"⌐"角正好变成一个指向右的折角。点位是确定的、与字体无关，
 * 且只用 `.border()` 与 `.rotate()` 两个基础能力。
 */
@Component
export struct IconChevron {
  build() {
    Row()
      .width(8)
      .height(8)
      .border({
        width: { top: 1.5, right: 1.5 },
        color: AppColor.textHint
      })
      .borderRadius(1)
      .rotate({ angle: 45 })
  }
}
