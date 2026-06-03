//
//  UserDB.swift
//  FuckYouXcode
//
//  Created by 马逸凡 on 2026/2/11.
//
import GRDB
import Foundation

actor UserDB {
    static let shared = UserDB()
    private(set) var dbQueue: DatabaseQueue!
    private let shouldIncludeHierarchyMigration: Bool

    init(
        dbQueue: DatabaseQueue? = nil,
        shouldIncludeHierarchyMigration: Bool = true
    ) {
        self.dbQueue = dbQueue
        self.shouldIncludeHierarchyMigration = shouldIncludeHierarchyMigration
    }

    func prepareIfNeeded() throws {///这个函数可能会“抛出错误”（失败时不会继续正常往下走，而是把错误往外传）
        
        if dbQueue == nil {
            let url = try UserStoragePaths.localUserDatabaseURL(createIfNeeded: true)
            dbQueue = try DatabaseQueue(path: url.path)
            print("✅ user_1.db path =", url.path)
        }
        
        // ✅ 注意：用 inDatabase，不要用 write（write 默认开事务）
         try dbQueue.inDatabase { db in
         try db.execute(sql: "PRAGMA foreign_keys = ON;")
         try db.execute(sql: "PRAGMA journal_mode = WAL;")
         try db.execute(sql: "PRAGMA synchronous = NORMAL;")
         }
         
         try migrator.migrate(dbQueue)
         }
         
         private var migrator: DatabaseMigrator {
         Self.makeMigrator(includeHierarchyMigration: shouldIncludeHierarchyMigration)
         }

         nonisolated static func makeMigrator(
            includeHierarchyMigration: Bool = true
         ) -> DatabaseMigrator {
         var migrator = DatabaseMigrator()
         
         migrator.registerMigration("v1_user_tables") { db in
         try db.execute(sql: Self.schemaSQL)
         }
        
         migrator.registerMigration("v2_word_groups") { db in
         try db.execute(sql: """
         CREATE TABLE IF NOT EXISTS word_groups (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           name TEXT NOT NULL UNIQUE,
           created_at INTEGER NOT NULL DEFAULT (unixepoch())
         );

         CREATE TABLE IF NOT EXISTS word_group_words (
           group_id INTEGER NOT NULL REFERENCES word_groups(id) ON DELETE CASCADE,
           word TEXT NOT NULL,
           created_at INTEGER NOT NULL DEFAULT (unixepoch()),
           PRIMARY KEY (group_id, word)
         );

         CREATE INDEX IF NOT EXISTS idx_word_group_words_group_created
         ON word_group_words(group_id, created_at DESC);
         """)
         }
        
         migrator.registerMigration("v3_visual_hidden_words") { db in
         try db.execute(sql: """
         CREATE TABLE IF NOT EXISTS collection_hidden_words (
           word TEXT PRIMARY KEY,
           created_at INTEGER NOT NULL DEFAULT (unixepoch())
         );
         """)
         }

         migrator.registerMigration("v4_word_group_media") { db in
         let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(word_groups)")
         let hasNoteColumn = columns.contains { row in
             (row["name"] as String?) == "note"
         }
         if !hasNoteColumn {
             try db.execute(sql: """
             ALTER TABLE word_groups
             ADD COLUMN note TEXT NOT NULL DEFAULT '';
             """)
         }

         try db.execute(sql: """
         CREATE TABLE IF NOT EXISTS word_group_images (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           group_id INTEGER NOT NULL REFERENCES word_groups(id) ON DELETE CASCADE,
           file_name TEXT NOT NULL,
           created_at INTEGER NOT NULL DEFAULT (unixepoch())
         );

         CREATE INDEX IF NOT EXISTS idx_word_group_images_group_created
         ON word_group_images(group_id, created_at DESC);
         """)
         }

         migrator.registerMigration("v5_word_group_image_asset_identifier") { db in
         let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(word_group_images)")
         let hasAssetIdentifierColumn = columns.contains { row in
             (row["name"] as String?) == "asset_identifier"
         }
         if !hasAssetIdentifierColumn {
             try db.execute(sql: """
             ALTER TABLE word_group_images
             ADD COLUMN asset_identifier TEXT;
             """)
         }

         try db.execute(sql: """
         CREATE UNIQUE INDEX IF NOT EXISTS uq_word_group_images_group_asset
         ON word_group_images(group_id, asset_identifier)
         WHERE asset_identifier IS NOT NULL;
         """)
         }

         migrator.registerMigration("v6_word_group_ocr_texts") { db in
         try db.execute(sql: """
         CREATE TABLE IF NOT EXISTS word_group_ocr_texts (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           group_id INTEGER NOT NULL REFERENCES word_groups(id) ON DELETE CASCADE,
           content TEXT NOT NULL,
           created_at INTEGER NOT NULL DEFAULT (unixepoch())
         );

         CREATE INDEX IF NOT EXISTS idx_word_group_ocr_texts_group_created
         ON word_group_ocr_texts(group_id, created_at DESC, id DESC);
         """)
         }

         migrator.registerMigration("v7_dictionary_scoped_marks") { db in
         let highlightColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(highlights)")
         let hasHighlightDictionaryID = highlightColumns.contains { row in
             (row["name"] as String?) == "dictionary_id"
         }
         if !hasHighlightDictionaryID {
             try db.execute(sql: """
             ALTER TABLE highlights
             ADD COLUMN dictionary_id TEXT NOT NULL DEFAULT 'builtin.default';
             """)
         }

         let annotationColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(annotations)")
         let hasAnnotationDictionaryID = annotationColumns.contains { row in
             (row["name"] as String?) == "dictionary_id"
         }
         if !hasAnnotationDictionaryID {
             try db.execute(sql: """
             ALTER TABLE annotations
             ADD COLUMN dictionary_id TEXT NOT NULL DEFAULT 'builtin.default';
             """)
         }

         try db.execute(sql: """
         DROP INDEX IF EXISTS uq_highlights_range_v2;
         CREATE UNIQUE INDEX IF NOT EXISTS uq_highlights_range_v3
         ON highlights(dictionary_id, entry_id, word, field, start, length);

         DROP INDEX IF EXISTS idx_highlights_word_entry_field;
         CREATE INDEX IF NOT EXISTS idx_highlights_word_entry_field
         ON highlights(word, dictionary_id, entry_id, field);

         DROP INDEX IF EXISTS idx_annotations_word_entry_field;
         CREATE INDEX IF NOT EXISTS idx_annotations_word_entry_field
         ON annotations(word, dictionary_id, entry_id, field);
         """)
         }

         if includeHierarchyMigration {
         migrator.registerMigration("v8_word_group_hierarchy") { db in
         let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(word_groups)")
         let hasKindColumn = columns.contains { row in
             (row["name"] as String?) == "kind"
         }
         if !hasKindColumn {
             try db.execute(sql: """
             ALTER TABLE word_groups
             ADD COLUMN kind TEXT NOT NULL DEFAULT 'group';
             """)
         }

         let hasParentGroupIDColumn = columns.contains { row in
             (row["name"] as String?) == "parent_group_id"
         }
         if !hasParentGroupIDColumn {
             try db.execute(sql: """
             ALTER TABLE word_groups
             ADD COLUMN parent_group_id INTEGER REFERENCES word_groups(id) ON DELETE SET NULL;
             """)
         }

         try db.execute(sql: """
         UPDATE word_groups
         SET kind = 'group'
         WHERE kind IS NULL OR TRIM(kind) = '';

         CREATE INDEX IF NOT EXISTS idx_word_groups_parent_group
         ON word_groups(parent_group_id);
         """)
         }

         migrator.registerMigration("v9_word_group_archival") { db in
         let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(word_groups)")
         let hasArchivedAtColumn = columns.contains { row in
             (row["name"] as String?) == "archived_at"
         }
         if !hasArchivedAtColumn {
             try db.execute(sql: """
             ALTER TABLE word_groups
             ADD COLUMN archived_at INTEGER;
             """)
         }

         try db.execute(sql: """
         CREATE INDEX IF NOT EXISTS idx_word_groups_archived_at
         ON word_groups(archived_at);
         """)
         }
         }
         
         return migrator
         }
         
         private static let schemaSQL = """
         -- =========================
         -- 1) 收藏 / 生词本（一个词一条记录）
         -- =========================
         CREATE TABLE IF NOT EXISTS favorites (
           word TEXT PRIMARY KEY,                 -- 关联键：词面
           created_at INTEGER NOT NULL DEFAULT (unixepoch())    --做时间戳
         );

         CREATE INDEX IF NOT EXISTS idx_favorites_created_at
         ON favorites(created_at DESC);

         -- =========================
         -- 2) 高亮（可多条，支持多段高亮）
         -- =========================
         CREATE TABLE IF NOT EXISTS highlights (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           entry_id INTEGER NOT NULL,

           word TEXT NOT NULL,                    -- 关联键：词面
           dictionary_id TEXT NOT NULL DEFAULT 'builtin.default',
           field TEXT NOT NULL DEFAULT 'definition',
           -- field: 你高亮的是哪个区域，例如 definition/examples/phrases/custom

           start INTEGER NOT NULL,                -- 以“该 field 的纯文本”计数的起点（UTF-16 index）
           length INTEGER NOT NULL,               -- 高亮长度（UTF-16 length）

           color TEXT NOT NULL DEFAULT 'yellow',  -- 'yellow'/'green'/'pink'... 你自己定义
           note TEXT NOT NULL DEFAULT '',         -- 可选：高亮附带的小备注（也可以不用）

           created_at INTEGER NOT NULL DEFAULT (unixepoch()),
           updated_at INTEGER NOT NULL DEFAULT (unixepoch())    --更新时间戳
         );


         --给某一列建“目录”，让你按这列查数据更快

         CREATE INDEX IF NOT EXISTS idx_highlights_word_entry_field    --复合索引让这个查询更快
         ON highlights(word, dictionary_id, entry_id, field);

         -- 支持用户自定义，修改高亮颜色
         DROP INDEX IF EXISTS uq_highlights_range;
         CREATE UNIQUE INDEX IF NOT EXISTS uq_highlights_range_v2
         ON highlights(dictionary_id, entry_id, word, field, start, length);

         -- =========================
         -- 3) 批注 / 笔记（两种：全文笔记 vs 针对某段 range）
         -- =========================
         CREATE TABLE IF NOT EXISTS annotations (
           id INTEGER PRIMARY KEY AUTOINCREMENT,

           word TEXT NOT NULL,                    -- 关联键：词面
           dictionary_id TEXT NOT NULL DEFAULT 'builtin.default',
           field TEXT NOT NULL DEFAULT 'definition',

           -- 如果 start/length 为 NULL：表示“整条词条/整段区域的笔记”
           start INTEGER,
           length INTEGER,

           content TEXT NOT NULL,                 -- 批注内容（用户输入）
           created_at INTEGER NOT NULL DEFAULT (unixepoch()),
           updated_at INTEGER NOT NULL DEFAULT (unixepoch())
         );

         ALTER TABLE annotations ADD COLUMN entry_id INTEGER;

         CREATE INDEX IF NOT EXISTS idx_annotations_word_entry_field
         ON annotations(word, dictionary_id, entry_id, field);

         -- 如果你希望同一段范围只能有一条批注，就打开这个 unique（可按需求）
         -- CREATE UNIQUE INDEX IF NOT EXISTS uq_annotations_range
         -- ON annotations(word, field, start, length);

         -- =========================
         -- 4) 统一更新时间：updated_at 自动更新（可选，但很实用）
         -- =========================
         CREATE TRIGGER IF NOT EXISTS trg_highlights_updated_at    --触发器更新时间戳
         AFTER UPDATE ON highlights
         BEGIN
           UPDATE highlights SET updated_at = unixepoch() WHERE id = NEW.id;
         END;

         CREATE TRIGGER IF NOT EXISTS trg_annotations_updated_at
         AFTER UPDATE ON annotations
         BEGIN
           UPDATE annotations SET updated_at = unixepoch() WHERE id = NEW.id;
         END;
         """
         }



/*         CREATE TABLE IF NOT EXISTS favorites (
 word TEXT PRIMARY KEY,
 created_at INTEGER NOT NULL DEFAULT (unixepoch())
 );
 
 CREATE INDEX IF NOT EXISTS idx_favorites_created_at
 ON favorites(created_at DESC);
 
 CREATE TABLE IF NOT EXISTS highlights (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 word TEXT NOT NULL,
 field TEXT NOT NULL DEFAULT 'definition',
 start INTEGER NOT NULL,
 length INTEGER NOT NULL,
 color TEXT NOT NULL DEFAULT 'yellow',
 note TEXT NOT NULL DEFAULT '',
 created_at INTEGER NOT NULL DEFAULT (unixepoch()),
 updated_at INTEGER NOT NULL DEFAULT (unixepoch())
 );
 
 CREATE INDEX IF NOT EXISTS idx_highlights_word
 ON highlights(word);
 
 CREATE INDEX IF NOT EXISTS idx_highlights_word_field
 ON highlights(word, field);
 
 CREATE UNIQUE INDEX IF NOT EXISTS uq_highlights_range
 ON highlights(word, field, start, length);
 
 CREATE TABLE IF NOT EXISTS annotations (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 word TEXT NOT NULL,
 field TEXT NOT NULL DEFAULT 'definition',
 start INTEGER,
 length INTEGER,
 content TEXT NOT NULL,
 created_at INTEGER NOT NULL DEFAULT (unixepoch()),
 updated_at INTEGER NOT NULL DEFAULT (unixepoch())
 );
 
 CREATE INDEX IF NOT EXISTS idx_annotations_word
 ON annotations(word);
 
 CREATE INDEX IF NOT EXISTS idx_annotations_word_field
 ON annotations(word, field);
 
 CREATE TRIGGER IF NOT EXISTS trg_highlights_updated_at
 AFTER UPDATE ON highlights
 BEGIN
 UPDATE highlights SET updated_at = unixepoch() WHERE id = NEW.id;
 END;
 
 CREATE TRIGGER IF NOT EXISTS trg_annotations_updated_at
 AFTER UPDATE ON annotations
 BEGIN
 UPDATE annotations SET updated_at = unixepoch() WHERE id = NEW.id;
 END;*/
