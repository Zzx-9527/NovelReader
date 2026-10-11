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
  /** AppConstants.FORMAT_TXT / FORMAT_EPUB */
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
  /** 扩展元数据（EPUB OPF 等） */
  metadata: string = '';
  deleted: number = 0;

  /** 是否尚未开始阅读 */
  hasNoProgress(): boolean {
    return this.lastChapterIndex < 0;
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
