import { ReadingPosition } from './ReadingPosition';
import { AppConstants } from '../common/constants/AppConstants';
import { DbConstants } from '../common/constants/DbConstants';

/**
 * 书籍（纯数据）。
 *
 * filePath / coverPath 是【沙箱相对路径】，不含 filesDir 前缀 ——
 * 拼接由 PathUtil 负责，绝对路径在应用升级后会失效。
 */
export class Book {
  id: number = 0;
  /** 稳定文件标识，用于沙箱文件名 */
  uuid: string = '';
  title: string = '';
  author: string = '';
  coverPath: string = '';
  filePath: string = '';
  /** 仅支持 TXT（EPUB 支持已评估并放弃，见 AppConstants.FORMAT_TXT 注释） */
  format: string = AppConstants.FORMAT_TXT;
  encoding: string = 'utf-8';
  fileSize: number = 0;
  /** 原始文件字节的 SHA-256，用于去重 */
  fileHash: string = '';
  /** null 表示未分组 */
  groupId: number | null = null;
  totalChapters: number = 0;
  wordCount: number = 0;
  addedAt: number = 0;
  updatedAt: number = 0;
  /** null 表示从未阅读 */
  lastReadAt: number | null = null;
  /** 0-based；-1 表示无进度 */
  lastChapterIndex: number = DbConstants.NO_PROGRESS;
  /** 章内 UTF-16 下标 */
  lastOffset: number = 0;
  readStatus: number = AppConstants.READ_STATUS_UNREAD;
  /** 0~1 */
  progressPercent: number = 0;
  /** ReadingPosition 的 JSON，与 lastChapterIndex/lastOffset 同源 */
  location: string = '';
  parseStatus: number = AppConstants.PARSE_PENDING;
  /** 解析失败原因（含"文件丢失"） */
  parseError: string = '';
  /** 命中的分章规则名，便于重新分章 */
  parseRule: string = '';
  /** 预留的扩展元数据 JSON（当前无消费者；解析器需要额外元数据时启用） */
  metadata: string = '';
  deleted: number = 0;

  /** 是否尚未开始阅读 */
  hasNoProgress(): boolean {
    return this.lastChapterIndex < 0;
  }

  /**
   * 列表项的键（供 `ForEach` 用）。
   *
   * ⚠️ **必须把"会显示出来的字段"都编进来**，不能只用 `id`。
   *
   * 这是本项目实测踩过的真实 bug：往分组里加了书之后，书架首页那个分组
   * 仍显示"0 本"。根因是 `ForEach` 在 key 不变时**复用组件实例、
   * 不再执行 item generator** —— 子组件的 `@Prop book` 就永远停在旧对象上。
   * 判据：**key 必须能区分"渲染结果不同"的两个状态**。
   *
   * ⚠️ 收在 `Book` 上而不是各处自己拼：书架首页、分组详情页、
   * 挑书页三处都在用 `ForEach` 渲染书籍，字段清单一旦分散，
   * 就必然出现"改了一处忘了另两处"（这正是本 bug 蔓延三处的原因）。
   *
   * ⚠️ 只编入**真正会显示**的字段（书名/作者/章节数/大小/进度/最近阅读），
   * 不要图省事把整个对象序列化：key 每变一次就重建一次组件，
   * 无关字段（如 `updatedAt`）会让列表白重建。
   */
  listKey(): string {
    return `${this.id}_${this.title}_${this.author}_${this.totalChapters}`
      + `_${this.fileSize}_${this.progressPercent}_${this.lastReadAt}`;
  }

  /** 是否已读完 */
  isFinished(): boolean {
    return this.readStatus === AppConstants.READ_STATUS_FINISHED;
  }

  position(): ReadingPosition {
    return ReadingPosition.fromJson(this.location);
  }

  /** 解析成通用阅读位置（以 last_chapter_index / last_offset 为准） */
  currentPosition(): ReadingPosition {
    const pos = this.position();
    pos.chapterIndex = this.lastChapterIndex;
    pos.offset = this.lastOffset;
    pos.percent = this.progressPercent;
    return pos;
  }
}
