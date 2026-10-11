/**
 * 数据库常量：库名、版本、表名、列名、哨兵值。
 *
 * 偏移量口径（设计文档 5.1 铁律 2）：
 *  - chapter.start_offset / end_offset  = 【原文件字节偏移】
 *  - annotation / page_cache / ReadingPosition.offset = 【章内 UTF-16 下标】
 *
 * 章节序号口径（铁律 1）：chapter_index 一律 0-based，"无进度"用 -1。
 */
export class DbConstants {
  static readonly DB_NAME: string = 'novel_reader.db';
  /** 结构版本。改动 DDL 必须同步 +1 并在 RdbHelper.migrate 里补步骤 */
  static readonly DB_VERSION: number = 1;

  static readonly TABLE_BOOK: string = 'book';
  static readonly TABLE_CHAPTER: string = 'chapter';
  static readonly TABLE_ANNOTATION: string = 'annotation';
  static readonly TABLE_BOOK_GROUP: string = 'book_group';
  static readonly TABLE_DAILY_STATS: string = 'reading_daily_stats';
  static readonly TABLE_PAGE_CACHE: string = 'page_cache';

  /** 统计表中代表"全局统计"的哨兵 book_id */
  static readonly GLOBAL_STATS_BOOK_ID: number = 0;
  /** 无进度哨兵值 */
  static readonly NO_PROGRESS: number = -1;
}

/** book 表列名 */
export class BookCol {
  static readonly ID: string = 'id';
  static readonly UUID: string = 'uuid';
  static readonly TITLE: string = 'title';
  static readonly AUTHOR: string = 'author';
  static readonly COVER_PATH: string = 'cover_path';
  static readonly FILE_PATH: string = 'file_path';
  static readonly FORMAT: string = 'format';
  static readonly ENCODING: string = 'encoding';
  static readonly FILE_SIZE: string = 'file_size';
  static readonly FILE_HASH: string = 'file_hash';
  static readonly GROUP_ID: string = 'group_id';
  static readonly TOTAL_CHAPTERS: string = 'total_chapters';
  static readonly WORD_COUNT: string = 'word_count';
  static readonly ADDED_AT: string = 'added_at';
  static readonly UPDATED_AT: string = 'updated_at';
  static readonly LAST_READ_AT: string = 'last_read_at';
  static readonly LAST_CHAPTER_INDEX: string = 'last_chapter_index';
  static readonly LAST_OFFSET: string = 'last_offset';
  static readonly READ_STATUS: string = 'read_status';
  static readonly PROGRESS_PERCENT: string = 'progress_percent';
  static readonly LOCATION: string = 'location';
  static readonly PARSE_STATUS: string = 'parse_status';
  static readonly PARSE_ERROR: string = 'parse_error';
  static readonly PARSE_RULE: string = 'parse_rule';
  static readonly METADATA: string = 'metadata';
  static readonly DELETED: string = 'deleted';

  /** 供 mapRow 使用的完整列清单，顺序与 ResultSet 查询列一致 */
  static readonly ALL: string =
    'id, uuid, title, author, cover_path, file_path, format, encoding, file_size, file_hash, ' +
    'group_id, total_chapters, word_count, added_at, updated_at, last_read_at, ' +
    'last_chapter_index, last_offset, read_status, progress_percent, location, ' +
    'parse_status, parse_error, parse_rule, metadata, deleted';

  /** 目录/详情用的精简列 */
  static readonly SUMMARY: string =
    'id, uuid, title, author, cover_path, file_path, format, encoding, file_size, ' +
    'group_id, total_chapters, word_count, added_at, updated_at, last_read_at, ' +
    'last_chapter_index, last_offset, read_status, progress_percent';
}

/** chapter 表列名 */
export class ChapterCol {
  static readonly ID: string = 'id';
  static readonly BOOK_ID: string = 'book_id';
  static readonly TITLE: string = 'title';
  static readonly START_OFFSET: string = 'start_offset';
  static readonly END_OFFSET: string = 'end_offset';
  static readonly HREF: string = 'href';
  static readonly ANCHOR: string = 'anchor';
  static readonly LEVEL: string = 'level';
  static readonly WORD_COUNT: string = 'word_count';
  static readonly CHAPTER_INDEX: string = 'chapter_index';
  static readonly CREATED_AT: string = 'created_at';
  static readonly UPDATED_AT: string = 'updated_at';

  static readonly ALL: string =
    'id, book_id, title, start_offset, end_offset, href, anchor, level, word_count, ' +
    'chapter_index, created_at, updated_at';

  /** 目录列表用的精简列（不含 href/anchor/时间戳） */
  static readonly SUMMARY: string =
    'id, book_id, title, start_offset, end_offset, chapter_index, level, word_count';
}

/** annotation 表列名 */
export class AnnotationCol {
  static readonly ID: string = 'id';
  static readonly BOOK_ID: string = 'book_id';
  static readonly CHAPTER_ID: string = 'chapter_id';
  static readonly CHAPTER_INDEX: string = 'chapter_index';
  static readonly START_OFFSET: string = 'start_offset';
  static readonly END_OFFSET: string = 'end_offset';
  static readonly SELECTED_TEXT: string = 'selected_text';
  static readonly NOTE_CONTENT: string = 'note_content';
  static readonly TYPE: string = 'type';
  static readonly COLOR: string = 'color';
  static readonly CREATED_AT: string = 'created_at';
  static readonly UPDATED_AT: string = 'updated_at';
  static readonly DELETED: string = 'deleted';

  static readonly ALL: string =
    'id, book_id, chapter_id, chapter_index, start_offset, end_offset, selected_text, ' +
    'note_content, type, color, created_at, updated_at, deleted';
}

/** book_group 表列名 */
export class GroupCol {
  static readonly ID: string = 'id';
  static readonly NAME: string = 'name';
  static readonly SORT_ORDER: string = 'sort_order';
  static readonly CREATED_AT: string = 'created_at';
  static readonly UPDATED_AT: string = 'updated_at';
  static readonly DELETED: string = 'deleted';

  static readonly ALL: string = 'id, name, sort_order, created_at, updated_at, deleted';
}

/** reading_daily_stats 表列名 */
export class StatsCol {
  static readonly ID: string = 'id';
  static readonly BOOK_ID: string = 'book_id';
  static readonly DATE: string = 'date';
  static readonly DURATION_SECONDS: string = 'duration_seconds';
  static readonly UPDATED_AT: string = 'updated_at';
}

/** page_cache 表列名 */
export class PageCacheCol {
  static readonly ID: string = 'id';
  static readonly BOOK_ID: string = 'book_id';
  static readonly CHAPTER_INDEX: string = 'chapter_index';
  static readonly LAYOUT_KEY: string = 'layout_key';
  static readonly BREAKS: string = 'breaks';
  static readonly PAGE_COUNT: string = 'page_count';
  static readonly UPDATED_AT: string = 'updated_at';
}
