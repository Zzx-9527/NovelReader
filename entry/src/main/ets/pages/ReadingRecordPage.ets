/**
 * ⚠️ **本文件已废弃，请手动删除。**
 *
 * 阅读记录原先是一个独立页面（`pages/ReadingRecordPage`），
 * 现已按用户要求**整体搬进「统计」Tab 的最末一块**：
 *
 *   `views/stats/StatsPage.ets` → `buildReadingRecord()`
 *   （总阅读时长 / 三格账目 / 各书时长列表 + 时长横条，原样搬入）
 *
 * 配套改动（都已生效）：
 *  - `resources/base/profile/main_pages.json` 里的 `pages/ReadingRecordPage` 已移除；
 *  - `model/RouteParam.ets` 里的 `RouteName.READING_RECORD_PAGE` 常量已删除；
 *  - 数据查询 `StatsService.loadReadingRecord()` / `StatsRepository.listBookDurations()`
 *    **保留**，由统计页调用；
 *  - `model/ReadingRecord.ets`（`BookReadingRecord` / `ReadingRecordSummary`）**保留**。
 *
 * ⚠️ 为什么这个文件还留着：本次改动时 shell 被工作区权限挡住
 * （`SetNamedSecurityInfoW failed (Win32 5)`），无法执行删除。
 * 它已不在 `main_pages.json` 里、也没有任何地方 import 它，
 * 因此**不影响功能**；但留着会在下次全量构建时被当成无用的 `@Entry` 页面编译。
 *
 * 删掉它即可，不需要任何其它改动。
 */
