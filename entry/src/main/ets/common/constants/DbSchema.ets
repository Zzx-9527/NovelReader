/**
 * 数据库建表与索引语句（v1）。
 * 详见 docs/小说阅读器设计文档.md 5.4。
 *
 * 执行约定：
 *  - 表顺序不可调换 —— book_group 必须先于 book，book 必须先于 chapter（外键依赖）；
 *  - 全部语句都是 IF NOT EXISTS，可反复执行，因此不需要"是否首次建库"的标志位；
 *  - 执行前必须先 PRAGMA foreign_keys = ON（RDB 默认关闭）。
 */

/** 建表语句，按外键依赖排序 */
export const CREATE_TABLE_SQL: string[] = [
  `CREATE TABLE IF NOT EXISTS book_group (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER,
    updated_at  INTEGER,
    deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
  )`,

  `CREATE TABLE IF NOT EXISTS book (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid               TEXT    NOT NULL,
    title              TEXT    NOT NULL,
    author             TEXT    NOT NULL DEFAULT '',
    cover_path         TEXT    NOT NULL DEFAULT '',
    file_path          TEXT    NOT NULL,
    format             TEXT    NOT NULL CHECK (format IN ('txt', 'epub')),
    encoding           TEXT    NOT NULL DEFAULT 'utf-8',
    file_size          INTEGER NOT NULL DEFAULT 0 CHECK (file_size >= 0),
    file_hash          TEXT    NOT NULL DEFAULT '',
    group_id           INTEGER,
    total_chapters     INTEGER NOT NULL DEFAULT 0 CHECK (total_chapters >= 0),
    word_count         INTEGER NOT NULL DEFAULT 0 CHECK (word_count >= 0),
    added_at           INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL,
    last_read_at       INTEGER,
    last_chapter_index INTEGER NOT NULL DEFAULT -1,
    last_offset        INTEGER NOT NULL DEFAULT 0 CHECK (last_offset >= 0),
    read_status        INTEGER NOT NULL DEFAULT 0 CHECK (read_status IN (0, 1, 2)),
    progress_percent   REAL    NOT NULL DEFAULT 0 CHECK (progress_percent >= 0 AND progress_percent <= 1),
    location           TEXT    NOT NULL DEFAULT '',
    parse_status       INTEGER NOT NULL DEFAULT 0 CHECK (parse_status IN (0, 1, 2, 3)),
    parse_error        TEXT    NOT NULL DEFAULT '',
    parse_rule         TEXT    NOT NULL DEFAULT '',
    metadata           TEXT    NOT NULL DEFAULT '',
    deleted            INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
    FOREIGN KEY (group_id) REFERENCES book_group(id) ON DELETE SET NULL
  )`,

  `CREATE TABLE IF NOT EXISTS chapter (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id       INTEGER NOT NULL,
    title         TEXT    NOT NULL DEFAULT '',
    start_offset  INTEGER,
    end_offset    INTEGER,
    href          TEXT    NOT NULL DEFAULT '',
    anchor        TEXT    NOT NULL DEFAULT '',
    level         INTEGER NOT NULL DEFAULT 0 CHECK (level >= 0),
    word_count    INTEGER NOT NULL DEFAULT 0 CHECK (word_count >= 0),
    chapter_index INTEGER NOT NULL,
    created_at    INTEGER,
    updated_at    INTEGER,
    UNIQUE (book_id, chapter_index),
    FOREIGN KEY (book_id) REFERENCES book(id) ON DELETE CASCADE
  )`,

  `CREATE TABLE IF NOT EXISTS annotation (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id       INTEGER NOT NULL,
    chapter_id    INTEGER NOT NULL,
    chapter_index INTEGER NOT NULL,
    start_offset  INTEGER,
    end_offset    INTEGER,
    selected_text TEXT    NOT NULL DEFAULT '',
    note_content  TEXT    NOT NULL DEFAULT '',
    type          INTEGER NOT NULL CHECK (type IN (1, 2, 3)),
    color         TEXT    NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    deleted       INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
    FOREIGN KEY (book_id)    REFERENCES book(id)    ON DELETE CASCADE,
    FOREIGN KEY (chapter_id) REFERENCES chapter(id) ON DELETE CASCADE
  )`,

  `CREATE TABLE IF NOT EXISTS reading_daily_stats (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id          INTEGER NOT NULL DEFAULT 0,
    date             TEXT    NOT NULL,
    duration_seconds INTEGER NOT NULL DEFAULT 0 CHECK (duration_seconds >= 0),
    book_title       TEXT    NOT NULL DEFAULT '',
    updated_at       INTEGER,
    UNIQUE (book_id, date)
  )`,

  `CREATE TABLE IF NOT EXISTS page_cache (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id       INTEGER NOT NULL,
    chapter_index INTEGER NOT NULL,
    layout_key    TEXT    NOT NULL,
    breaks        TEXT    NOT NULL DEFAULT '',
    page_count    INTEGER NOT NULL DEFAULT 0,
    updated_at    INTEGER,
    UNIQUE (book_id, chapter_index, layout_key),
    FOREIGN KEY (book_id) REFERENCES book(id) ON DELETE CASCADE
  )`
];

/**
 * 索引语句。
 *
 * 刻意不建的两条（它们与各自的 UNIQUE 约束完全重复，只会拖慢批量导入）：
 *   idx_chapter_book(book_id, chapter_index)  -- UNIQUE(book_id, chapter_index) 已覆盖
 *   idx_stats_book(book_id, date)             -- UNIQUE(book_id, date) 已覆盖
 */
export const CREATE_INDEX_SQL: string[] = [
  // 书架：查询必定带 deleted = 0，因此主查询列放最前
  `CREATE UNIQUE INDEX IF NOT EXISTS uq_book_uuid ON book(uuid)`,
  `CREATE UNIQUE INDEX IF NOT EXISTS uq_book_hash ON book(file_hash) WHERE deleted = 0 AND file_hash <> ''`,
  `CREATE INDEX IF NOT EXISTS idx_book_shelf ON book(deleted, last_read_at DESC)`,
  `CREATE INDEX IF NOT EXISTS idx_book_group ON book(group_id, deleted)`,
  `CREATE INDEX IF NOT EXISTS idx_book_status ON book(deleted, read_status, last_read_at DESC)`,

  // 章节标题搜索（目录按序号查询走 UNIQUE 隐式索引）
  `CREATE INDEX IF NOT EXISTS idx_chapter_title ON chapter(book_id, title)`,

  // 标注
  `CREATE INDEX IF NOT EXISTS idx_annotation_book ON annotation(book_id, chapter_index, deleted)`,
  `CREATE INDEX IF NOT EXISTS idx_annotation_chapter ON annotation(chapter_id, deleted)`,
  `CREATE INDEX IF NOT EXISTS idx_annotation_type ON annotation(book_id, type, deleted)`,

  // 分组
  `CREATE UNIQUE INDEX IF NOT EXISTS uq_group_name ON book_group(name) WHERE deleted = 0`,
  `CREATE INDEX IF NOT EXISTS idx_group_sort ON book_group(deleted, sort_order, id)`,

  // 统计
  `CREATE UNIQUE INDEX IF NOT EXISTS uq_stats_book_date ON reading_daily_stats(book_id, date)`,
  `CREATE INDEX IF NOT EXISTS idx_stats_date ON reading_daily_stats(date)`,

  // 分页缓存
  `CREATE UNIQUE INDEX IF NOT EXISTS uq_page_cache ON page_cache(book_id, chapter_index, layout_key)`,
  `CREATE INDEX IF NOT EXISTS idx_page_cache_book ON page_cache(book_id)`
];
