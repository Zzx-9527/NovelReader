import { Book } from './Book';
import { BookGroup } from './BookGroup';

/**
 * 书架首页的**一条内容**：要么是一个分组，要么是一本书。
 *
 * ⚠️ 为什么需要这个包装类（而不是像早期那样"分组一个 `ForEach`、
 * 书一个 `ForEach`"）：
 *
 * 分组在首页里**就相当于一本书**（用户明确要求），所以两者必须**混排**
 * 在同一套排序规则下。而 `ForEach` 只能按数组顺序渲染 ——
 * 写两个 `ForEach` 的结果必然是"所有分组在前、所有书在后"，
 * 无论各自内部怎么排都做不到交错。
 *
 * 判据：**要交错渲染，就必须先交错成一条数组**。
 *
 * ⚠️ `group` / `book` 用非空默认值，而不是 `X | null`：
 * 一是省去渲染处的判空分支（`@Builder` 的 UI 体里**不能声明局部变量**，
 * 没法把 `entry.group` 收窄到局部变量再判断，见 `GroupCover` 的同类说明）；
 * 二是 `BookGroup` / `Book` 都是纯数据类，多建一个空实例的代价可忽略
 * （首页条目量级是几十到几百）。
 */
export class ShelfEntry {
  /** true = 分组条目，false = 书籍条目 */
  isGroup: boolean = false;
  /** `isGroup` 为 true 时有效 */
  group: BookGroup = new BookGroup();
  /** `isGroup` 为 false 时有效 */
  book: Book = new Book();

  /**
   * 列表项的键。
   *
   * ⚠️ **必须把"会影响渲染的字段"编进来**，不能只用 id。
   *
   * 这是本项目实测踩过的一个真实 bug：往分组里加了书之后，
   * 书架首页那个分组**仍显示"0 本"**（分组详情页里明明有那本书）。
   * 原因是 `ForEach` 在 key 不变时会**复用组件实例、不再执行
   * item generator** —— 子组件的 `@Prop group` 就永远停在旧对象上。
   * 而同一批里"被移出未分组列表"的那本书之所以显示正确，
   * 恰恰是因为它的 key 整个消失了、条目被真正移除重建。
   *
   * 判据：**key 必须能区分"渲染结果不同"的两个状态**。
   *
   * ⚠️ 书籍部分**复用 `Book.listKey()`**，不在这里另写一份字段清单：
   * 书架首页、分组详情页、挑书页三处都用 `ForEach` 渲染书籍，
   * 清单分散就必然"改一处忘两处"（这个 bug 就是这么蔓延到三处的）。
   */
  key(): string {
    if (this.isGroup) {
      return `g${this.groupKey()}`;
    }
    // 前缀必须保留：分组与书的 id 来自不同的表、各自从 1 开始，
    // 不区分就会撞 key（表现为"某个分组显示成了某本书"）
    return `b${this.book.listKey()}`;
  }

  /**
   * 分组键：id + 名称 + 数量 + 封面里那几本书。
   *
   * ⚠️ 封面**必须**进 key：`GroupCover` 显示的是组内前几本书的首字，
   * 只算数量的话，"把 A 书换成 B 书、数量不变"就不会重画。
   *
   * ⚠️ 用 `for` 循环拼串而不是 `Array.map().join()`：
   * 与本项目其余代码保持同一风格，也避免多一次中间数组分配。
   */
  private groupKey(): string {
    const group: BookGroup = this.group;
    let covers: string = '';
    for (const book of group.coverBooks) {
      covers += `${book.listKey()},`;
    }
    return `${group.id}_${group.name}_${group.bookCount}_${covers}`;
  }
}
