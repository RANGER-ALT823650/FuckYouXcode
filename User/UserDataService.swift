//
//  UserDataService.swift
//  FuckYouXcode
//
//  Created by 马逸凡 on 2026/2/12.
//
import Foundation
import GRDB

actor UserDataService {
    
    static let shared = UserDataService()
    
    private let db: UserDB

    init(db: UserDB = .shared) {
        self.db = db
    }

    private func notifyLocalMutation() async {
        // TEMP: iCloud disabled
        // await UserCloudSyncService.shared.notifyLocalMutation()
    }
    
    func isFavorite(word: String) async -> Bool {
        
        do {
            return try await db.dbQueue.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM favorites WHERE word = ?
                    )
                    """,
                    arguments: [word]
                ) ?? false
            }
            
        } catch {
            print(error)
            return false
        }
    }
    
    
    func toggleFavorite(word: String) async throws -> Bool {
        let isFavorite = try await db.dbQueue.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM favorites WHERE word = ?",
                arguments: [word]
            ) != nil

            if exists {
                try db.execute(
                    sql: "DELETE FROM favorites WHERE word = ?",
                    arguments: [word]
                )
                return false
            } else {
                try db.execute(
                    sql: "INSERT INTO favorites(word) VALUES(?)",
                    arguments: [word]
                )
                return true
            }
        }

        await notifyLocalMutation()
        return isFavorite
    }

    func addFavorite(word: String) async throws -> Bool {
        let didInsert = try await db.dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO favorites(word) VALUES(?)",
                arguments: [word]
            )
            return db.changesCount > 0
        }

        if didInsert {
            await notifyLocalMutation()
        }
        return didInsert
    }

    func removeFavorite(word: String) async {
        do {
            try await db.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM favorites WHERE word = ?",
                    arguments: [word]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("removeFavorite error:", error)
        }
    }

    func removeHighlights(word: String) async {
        do {
            try await db.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM highlights WHERE word = ?",
                    arguments: [word]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("removeHighlights error:", error)
        }
    }

    func removeAnnotations(word: String) async {
        do {
            try await db.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM annotations WHERE word = ?",
                    arguments: [word]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("removeAnnotations error:", error)
        }
    }
    
    struct Highlight: FetchableRecord, Codable, Identifiable {
        var id: Int64
        var word: String
        var dictionary_id: String
        var entry_id: Int64
        var field: String
        var start: Int
        var length: Int
        var color: String
        var note: String
        var created_at: Int64
        var updated_at: Int64
    }
    
    struct Annotation: FetchableRecord, Codable, Identifiable {
        var id: Int64
        var word: String
        var dictionary_id: String
        var entry_id: Int64
        var field: String
        var start: Int?
        var length: Int?
        var content: String
        var created_at: Int64
        var updated_at: Int64
    }

    enum WordGroupKind: String, Codable, CaseIterable, DatabaseValueConvertible {
        case group
        case parent
    }
    
    struct WordGroupSummary: FetchableRecord, Decodable, Identifiable {
        var id: Int64
        var name: String
        var wordCount: Int
        var lastModifiedAt: Int64
        var kind: WordGroupKind
        var parentGroupID: Int64?
        var parentName: String?
        var archivedAt: Int64?

        var breadcrumbName: String {
            guard let parentName, !parentName.isEmpty else { return name }
            return "\(parentName) / \(name)"
        }
    }

    struct WordGroupDetail: FetchableRecord, Decodable, Identifiable {
        var id: Int64
        var name: String
        var note: String
    }

    struct WordGroupImageRef: FetchableRecord, Decodable, Identifiable {
        var id: Int64
        var groupID: Int64
        var fileName: String
        var assetIdentifier: String?
        var createdAt: Int64
    }

    struct WordGroupImageInput {
        var imageData: Data
        var assetIdentifier: String?
    }

    struct WordGroupOCRText: FetchableRecord, Decodable, Identifiable {
        var id: Int64
        var groupID: Int64
        var content: String
        var createdAt: Int64
    }
    
    
    
    // MARK: - 1) 拉高亮
    /*func fetchHighlights(word: String, entry_id: Int64, field: String) async -> [Highlight] {
        do {
            return try await db.dbQueue.read { db in
                try Highlight.fetchAll(
                    db,
                    sql: """
                    SELECT id, word, entry_id, field, start, length, color, note, created_at, updated_at
                    FROM highlights
                    WHERE word = ? AND field = ? AND (entry_id = ? OR entry_id IS NULL)
                    ORDER BY start ASC
                    """,
                    arguments: [word, entry_id, field]
                )
            }
        } catch {
            print("fetchHighlights error:", error)
            return []
        }
    }*/
    
    // MARK: - 2) 判断是否存在“同 range”的高亮（同 word/field/start/length/color）
    func hasExactHighlight(
        word: String,
        dictionaryID: String,
        entry_id: Int64,
        field: String,
        start: Int,
        length: Int,
        color: String = "yellow"
    ) async -> Bool {
        do {
            return try await db.dbQueue.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM highlights
                        WHERE word = ?
                          AND dictionary_id = ?
                          AND entry_id = ?
                          AND field = ?
                          AND start = ?
                          AND length = ?
                          AND color = ?
                    )
                    """,
                    arguments: [word, dictionaryID, entry_id, field, start, length, color]
                ) ?? false
            }
        } catch {
            print("hasExactHighlight error:", error)
            return false
        }
    }
    
    // MARK: - 3)
    
    func setHighlight(
        word: String,
        dictionaryID: String,
        entry_id: Int64,
        field: String,
        start: Int,
        length: Int,
        color: String,
        note: String = ""
    ) async {
        do {
            try await db.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO highlights (word, dictionary_id, entry_id, field, start, length, color, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(dictionary_id, entry_id, word, field, start, length)
                    DO UPDATE SET
                        color = excluded.color,
                        note = excluded.note,
                        updated_at = unixepoch()
                    """,
                    arguments: [word, dictionaryID, entry_id, field, start, length, color, note]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("setHighlight error:", error)
        }
    }

    func removeHighlight(
        word: String,
        dictionaryID: String,
        entry_id: Int64,
        field: String,
        start: Int,
        length: Int
    ) async {
        do {
            try await db.dbQueue.write { db in
                try db.execute(
                    sql: """
                    DELETE FROM highlights
                    WHERE word = ?
                      AND dictionary_id = ?
                      AND entry_id = ?
                      AND field = ?
                      AND start = ?
                      AND length = ?
                    """,
                    arguments: [word, dictionaryID, entry_id, field, start, length]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("removeHighlight error:", error)
        }
    }

    
    // MARK: - 4) 新增批注（对某段 range）
    func addAnnotation(
        word: String,
        dictionaryID: String,
        entry_id: Int64,
        field: String,
        start: Int,
        length: Int,
        content: String
    ) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        do {
            try await db.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO annotations
                    (word, dictionary_id, entry_id, field, start, length, content)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [word, dictionaryID, entry_id, field, start, length, trimmed]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("addAnnotation error:", error)
        }
    }
    
    func removeAnnotation(id: Int64) async {
        do {
            try await db.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM annotations WHERE id = ?",
                    arguments: [id]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("removeAnnotation error:", error)
        }
    }
    
    // MARK: - 5) 拉批注（用于显示）
    /*func fetchAnnotations(word: String, entry_id: Int64, field: String) async -> [Annotation] {
        do {
            return try await db.dbQueue.read { db in
                try Annotation.fetchAll(
                    db,
                    sql: """
                    SELECT id, word, entry_id, field, start, length, color, note, created_at, updated_at
                    FROM annotations
                    WHERE word = ? AND field = ? AND (entry_id = ? OR entry_id IS NULL)
                    ORDER BY start ASC
                    """,
                    arguments: [word, entry_id, field]
                )
            }
        } catch {
            print("fetchAnnotations error:", error)
            return []
        }
    }*/
    
    
    
    
    func fetchHighlights(word: String, dictionaryID: String) async -> [Highlight] {
        do {
            return try await db.dbQueue.read { db in
                try Highlight.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM highlights
                    WHERE word = ? AND dictionary_id = ?
                    """,
                    arguments: [word, dictionaryID]
                )
            }
        } catch {
            print("fetchHighlights(word:dictionaryID:) error:", error)
            return []
        }
    }

    func fetchAnnotations(word: String, dictionaryID: String) async -> [Annotation] {
        do {
            return try await db.dbQueue.read { db in
                try Annotation.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM annotations
                    WHERE word = ? AND dictionary_id = ?
                    """,
                    arguments: [word, dictionaryID]
                )
            }
        } catch {
            print("fetchAnnotations(word:dictionaryID:) error:", error)
            return []
        }
    }
    
    func fetchFavoriteWords() async -> [String] {
        do {
            return try await db.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT word
                    FROM favorites
                    ORDER BY created_at DESC, word ASC
                    """
                )
            }
        } catch {
            print("fetchFavoriteWords error:", error)
            return []
        }
    }
    
    func fetchHighlightedWords() async -> [String] {
        do {
            return try await db.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT word
                    FROM highlights
                    GROUP BY word
                    ORDER BY MAX(updated_at) DESC, word ASC
                    """
                )
            }
        } catch {
            print("fetchHighlightedWords error:", error)
            return []
        }
    }
    
    func fetchAnnotatedWords() async -> [String] {
        do {
            return try await db.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT word
                    FROM annotations
                    GROUP BY word
                    ORDER BY MAX(updated_at) DESC, word ASC
                    """
                )
            }
        } catch {
            print("fetchAnnotatedWords error:", error)
            return []
        }
    }

    func fetchLatestHighlightDisplayTexts(words: [String]) async -> [String: String] {
        let candidates = Self.normalizedWords(words)
        guard !candidates.isEmpty else { return [:] }

        do {
            return try await db.dbQueue.read { db in
                let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT h.word AS word, h.note AS text
                    FROM highlights h
                    WHERE h.word IN (\(placeholders))
                      AND NOT EXISTS (
                        SELECT 1
                        FROM highlights h2
                        WHERE h2.word = h.word
                          AND (
                            h2.updated_at > h.updated_at
                            OR (h2.updated_at = h.updated_at AND h2.id > h.id)
                          )
                      )
                    """,
                    arguments: StatementArguments(candidates)
                )

                var result: [String: String] = [:]
                result.reserveCapacity(rows.count)
                for row in rows {
                    guard let word: String = row["word"] else { continue }
                    let text: String? = row["text"]
                    guard let normalizedText = Self.normalizedDisplayText(text) else { continue }
                    result[word] = normalizedText
                }
                return result
            }
        } catch {
            print("fetchLatestHighlightDisplayTexts error:", error)
            return [:]
        }
    }

    func fetchLatestAnnotationDisplayTexts(words: [String]) async -> [String: String] {
        let candidates = Self.normalizedWords(words)
        guard !candidates.isEmpty else { return [:] }

        do {
            return try await db.dbQueue.read { db in
                let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT a.word AS word, a.content AS text
                    FROM annotations a
                    WHERE a.word IN (\(placeholders))
                      AND NOT EXISTS (
                        SELECT 1
                        FROM annotations a2
                        WHERE a2.word = a.word
                          AND (
                            a2.updated_at > a.updated_at
                            OR (a2.updated_at = a.updated_at AND a2.id > a.id)
                          )
                      )
                    """,
                    arguments: StatementArguments(candidates)
                )

                var result: [String: String] = [:]
                result.reserveCapacity(rows.count)
                for row in rows {
                    guard let word: String = row["word"] else { continue }
                    let text: String? = row["text"]
                    guard let normalizedText = Self.normalizedDisplayText(text) else { continue }
                    result[word] = normalizedText
                }
                return result
            }
        } catch {
            print("fetchLatestAnnotationDisplayTexts error:", error)
            return [:]
        }
    }
    
    private static func normalizedWords(_ words: [String]) -> [String] {
        Array(
            Set(
                words
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
    }

    private static func normalizedDisplayText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.isEmpty ? nil : normalized
    }

    private static func wordGroupEffectiveLastModifiedSQL(alias: String) -> String {
        """
        MAX(
            \(alias).created_at,
            COALESCE(
                (SELECT MAX(w.created_at) FROM word_group_words w WHERE w.group_id = \(alias).id),
                \(alias).created_at
            ),
            COALESCE(
                (SELECT MAX(i.created_at) FROM word_group_images i WHERE i.group_id = \(alias).id),
                \(alias).created_at
            ),
            COALESCE(
                (SELECT MAX(t.created_at) FROM word_group_ocr_texts t WHERE t.group_id = \(alias).id),
                \(alias).created_at
            )
        )
        """
    }

    private static func wordGroupSummaryQuery(
        whereClause: String,
        orderBy: String = "lastModifiedAt DESC, g.id DESC"
    ) -> String {
        let groupLastModifiedSQL = wordGroupEffectiveLastModifiedSQL(alias: "g")
        let childLastModifiedSQL = wordGroupEffectiveLastModifiedSQL(alias: "c")

        return """
        SELECT g.id,
               g.name,
               CASE
                   WHEN g.kind = 'group' THEN (
                       SELECT COUNT(*)
                       FROM word_group_words w
                       WHERE w.group_id = g.id
                   )
                   ELSE 0
               END AS wordCount,
               CASE
                   WHEN g.kind = 'parent' THEN MAX(
                       g.created_at,
                       COALESCE(
                           (
                               SELECT MAX(\(childLastModifiedSQL))
                               FROM word_groups c
                               WHERE c.parent_group_id = g.id
                                 AND c.kind = 'group'
                           ),
                           g.created_at
                       )
                   )
                   ELSE \(groupLastModifiedSQL)
               END AS lastModifiedAt,
               g.kind,
               g.parent_group_id AS parentGroupID,
               p.name AS parentName,
               g.archived_at AS archivedAt
        FROM word_groups g
        LEFT JOIN word_groups p ON p.id = g.parent_group_id
        WHERE \(whereClause)
        ORDER BY \(orderBy)
        """
    }

    private static func wordGroupKind(db: Database, groupID: Int64) throws -> WordGroupKind? {
        guard let rawKind = try String.fetchOne(
            db,
            sql: """
            SELECT kind
            FROM word_groups
            WHERE id = ?
            """,
            arguments: [groupID]
        ) else {
            return nil
        }

        return WordGroupKind(rawValue: rawKind)
    }

    private static func isRealWordGroup(db: Database, groupID: Int64) throws -> Bool {
        try wordGroupKind(db: db, groupID: groupID) == .group
    }

    private static func isParentWordGroup(db: Database, groupID: Int64) throws -> Bool {
        try wordGroupKind(db: db, groupID: groupID) == .parent
    }

    private static func isUnarchivedRealWordGroup(db: Database, groupID: Int64) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM word_groups
                WHERE id = ?
                  AND kind = 'group'
                  AND archived_at IS NULL
            )
            """,
            arguments: [groupID]
        ) ?? false
    }

    private static func isUnarchivedParentWordGroup(db: Database, groupID: Int64) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM word_groups
                WHERE id = ?
                  AND kind = 'parent'
                  AND archived_at IS NULL
            )
            """,
            arguments: [groupID]
        ) ?? false
    }

    private static func uniqueWordGroupName(
        db: Database,
        originalName: String,
        excludingGroupID: Int64? = nil
    ) throws -> String {
        var finalName = originalName
        var suffix = 2

        while (try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM word_groups
                WHERE name = ?
                  AND (? IS NULL OR id <> ?)
            )
            """,
            arguments: [finalName, excludingGroupID, excludingGroupID]
        ) ?? false) {
            finalName = "\(originalName) (\(suffix))"
            suffix += 1
        }

        return finalName
    }

    private struct DeletedWordGroupAssets {
        var groupID: Int64
        var imageFileNames: [String]
    }

    private static func deleteWordGroupAndPurgeCollections(
        db: Database,
        groupID: Int64
    ) throws -> DeletedWordGroupAssets? {
        guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return nil }

        let imageFileNames = try String.fetchAll(
            db,
            sql: """
            SELECT file_name
            FROM word_group_images
            WHERE group_id = ?
            """,
            arguments: [groupID]
        )

        try db.execute(
            sql: """
            DELETE FROM favorites
            WHERE word IN (
                SELECT word FROM word_group_words WHERE group_id = ?
            )
            """,
            arguments: [groupID]
        )

        try db.execute(
            sql: """
            DELETE FROM highlights
            WHERE word IN (
                SELECT word FROM word_group_words WHERE group_id = ?
            )
            """,
            arguments: [groupID]
        )

        try db.execute(
            sql: """
            DELETE FROM annotations
            WHERE word IN (
                SELECT word FROM word_group_words WHERE group_id = ?
            )
            """,
            arguments: [groupID]
        )

        try db.execute(
            sql: "DELETE FROM word_groups WHERE id = ?",
            arguments: [groupID]
        )

        return DeletedWordGroupAssets(groupID: groupID, imageFileNames: imageFileNames)
    }

    private static func deleteFavoritesForWordsInGroups(
        db: Database,
        groupIDs: [Int64]
    ) throws {
        let uniqueGroupIDs = Array(Set(groupIDs)).sorted()
        guard !uniqueGroupIDs.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: uniqueGroupIDs.count).joined(separator: ",")
        try db.execute(
            sql: """
            DELETE FROM favorites
            WHERE word IN (
                SELECT word
                FROM word_group_words
                WHERE group_id IN (\(placeholders))
            )
            """,
            arguments: StatementArguments(uniqueGroupIDs)
        )
    }

    private static func restoreFavoritesForWordsInGroups(
        db: Database,
        groupIDs: [Int64]
    ) throws {
        let uniqueGroupIDs = Array(Set(groupIDs)).sorted()
        guard !uniqueGroupIDs.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: uniqueGroupIDs.count).joined(separator: ",")
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO favorites(word)
            SELECT DISTINCT word
            FROM word_group_words
            WHERE group_id IN (\(placeholders))
            """,
            arguments: StatementArguments(uniqueGroupIDs)
        )
    }

    private static func realGroupIDsForArchiveMutation(
        db: Database,
        groupID: Int64,
        kind: WordGroupKind
    ) throws -> [Int64] {
        switch kind {
        case .group:
            return [groupID]
        case .parent:
            return try Int64.fetchAll(
                db,
                sql: """
                SELECT id
                FROM word_groups
                WHERE parent_group_id = ?
                  AND kind = 'group'
                """,
                arguments: [groupID]
            )
        }
    }

    private func removeDeletedWordGroupAssets(_ deletedGroups: [DeletedWordGroupAssets]) {
        for deletedGroup in deletedGroups {
            for fileName in deletedGroup.imageFileNames {
                do {
                    let fileURL = try wordGroupImageFileURL(groupID: deletedGroup.groupID, fileName: fileName)
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    let nsError = error as NSError
                    if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                        print("removeDeletedWordGroupAssets remove image error:", error)
                    }
                }
            }

            do {
                let directoryURL = try wordGroupImagesDirectoryURL(groupID: deletedGroup.groupID, createIfNeeded: false)
                try FileManager.default.removeItem(at: directoryURL)
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                    print("removeDeletedWordGroupAssets remove image directory error:", error)
                }
            }
        }
    }

    func fetchWordGroups() async -> [WordGroupSummary] {
        await fetchRootWordGroups()
    }

    func fetchRootWordGroups() async -> [WordGroupSummary] {
        do {
            let sql = Self.wordGroupSummaryQuery(
                whereClause: "g.parent_group_id IS NULL AND g.archived_at IS NULL"
            )
            return try await db.dbQueue.read { db in
                try WordGroupSummary.fetchAll(db, sql: sql)
            }
        } catch {
            print("fetchRootWordGroups error:", error)
            return []
        }
    }

    func fetchChildWordGroups(
        parentGroupID: Int64,
        includeArchivedChildren: Bool = false
    ) async -> [WordGroupSummary] {
        do {
            let archivePredicate = includeArchivedChildren ? "1 = 1" : "g.archived_at IS NULL"
            let sql = Self.wordGroupSummaryQuery(
                whereClause: "g.parent_group_id = ? AND g.kind = 'group' AND \(archivePredicate)"
            )
            return try await db.dbQueue.read { db in
                guard try Self.isParentWordGroup(db: db, groupID: parentGroupID) else { return [] }
                return try WordGroupSummary.fetchAll(
                    db,
                    sql: sql,
                    arguments: [parentGroupID]
                )
            }
        } catch {
            print("fetchChildWordGroups error:", error)
            return []
        }
    }

    func fetchSelectableWordGroups() async -> [WordGroupSummary] {
        do {
            let sql = Self.wordGroupSummaryQuery(
                whereClause: """
                g.kind = 'group'
                AND g.archived_at IS NULL
                AND (g.parent_group_id IS NULL OR p.archived_at IS NULL)
                """
            )
            return try await db.dbQueue.read { db in
                try WordGroupSummary.fetchAll(db, sql: sql)
            }
        } catch {
            print("fetchSelectableWordGroups error:", error)
            return []
        }
    }

    func fetchArchivedWordGroups() async -> [WordGroupSummary] {
        do {
            let sql = Self.wordGroupSummaryQuery(
                whereClause: "g.archived_at IS NOT NULL",
                orderBy: "g.archived_at DESC, g.id DESC"
            )
            return try await db.dbQueue.read { db in
                try WordGroupSummary.fetchAll(db, sql: sql)
            }
        } catch {
            print("fetchArchivedWordGroups error:", error)
            return []
        }
    }

    func archiveWordGroup(groupID: Int64) async -> Bool {
        do {
            let didArchive = try await db.dbQueue.write { db in
                guard let kind = try Self.wordGroupKind(db: db, groupID: groupID) else {
                    return false
                }

                let groupIDsForFavoriteRemoval = try Self.realGroupIDsForArchiveMutation(
                    db: db,
                    groupID: groupID,
                    kind: kind
                )

                try db.execute(
                    sql: """
                    UPDATE word_groups
                    SET archived_at = unixepoch()
                    WHERE id = ?
                      AND archived_at IS NULL
                    """,
                    arguments: [groupID]
                )
                guard db.changesCount > 0 else { return false }

                try Self.deleteFavoritesForWordsInGroups(
                    db: db,
                    groupIDs: groupIDsForFavoriteRemoval
                )
                return true
            }
            if didArchive {
                await notifyLocalMutation()
            }
            return didArchive
        } catch {
            print("archiveWordGroup error:", error)
            return false
        }
    }

    func restoreWordGroupFromArchive(groupID: Int64) async -> Bool {
        do {
            let didRestore = try await db.dbQueue.write { db in
                guard let kind = try Self.wordGroupKind(db: db, groupID: groupID) else {
                    return false
                }

                let groupIDsForFavoriteRestore = try Self.realGroupIDsForArchiveMutation(
                    db: db,
                    groupID: groupID,
                    kind: kind
                )

                try db.execute(
                    sql: """
                    UPDATE word_groups
                    SET archived_at = NULL
                    WHERE id = ?
                      AND archived_at IS NOT NULL
                    """,
                    arguments: [groupID]
                )
                guard db.changesCount > 0 else { return false }

                try Self.restoreFavoritesForWordsInGroups(
                    db: db,
                    groupIDs: groupIDsForFavoriteRestore
                )
                return true
            }
            if didRestore {
                await notifyLocalMutation()
            }
            return didRestore
        } catch {
            print("restoreWordGroupFromArchive error:", error)
            return false
        }
    }

    func fetchWordGroupDetail(groupID: Int64) async -> WordGroupDetail? {
        do {
            return try await db.dbQueue.read { db in
                guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return nil }
                return try WordGroupDetail.fetchOne(
                    db,
                    sql: """
                    SELECT id, name, note
                    FROM word_groups
                    WHERE id = ?
                    """,
                    arguments: [groupID]
                )
            }
        } catch {
            print("fetchWordGroupDetail error:", error)
            return nil
        }
    }

    func updateWordGroupNote(groupID: Int64, note: String) async {
        do {
            try await db.dbQueue.write { db in
                guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return }
                try db.execute(
                    sql: """
                    UPDATE word_groups
                    SET note = ?
                    WHERE id = ?
                    """,
                    arguments: [note, groupID]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("updateWordGroupNote error:", error)
        }
    }

    func fetchWordGroupOCRTexts(groupID: Int64) async -> [WordGroupOCRText] {
        do {
            return try await db.dbQueue.read { db in
                guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return [] }
                return try WordGroupOCRText.fetchAll(
                    db,
                    sql: """
                    SELECT id,
                           group_id AS groupID,
                           content,
                           created_at AS createdAt
                    FROM word_group_ocr_texts
                    WHERE group_id = ?
                    ORDER BY created_at DESC, id DESC
                    """,
                    arguments: [groupID]
                )
            }
        } catch {
            print("fetchWordGroupOCRTexts error:", error)
            return []
        }
    }

    func appendWordGroupOCRText(groupID: Int64, text: String) async {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        do {
            try await db.dbQueue.write { db in
                guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return }
                try db.execute(
                    sql: """
                    INSERT INTO word_group_ocr_texts(group_id, content)
                    VALUES (?, ?)
                    """,
                    arguments: [groupID, normalized]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("appendWordGroupOCRText error:", error)
        }
    }

    func replaceWordGroupOCRText(groupID: Int64, text: String) async {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await db.dbQueue.write { db in
                guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return }
                try db.execute(
                    sql: """
                    DELETE FROM word_group_ocr_texts
                    WHERE group_id = ?
                    """,
                    arguments: [groupID]
                )

                guard !normalized.isEmpty else { return }

                try db.execute(
                    sql: """
                    INSERT INTO word_group_ocr_texts(group_id, content)
                    VALUES (?, ?)
                    """,
                    arguments: [groupID, normalized]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("replaceWordGroupOCRText error:", error)
        }
    }

    func fetchWordGroupImageRefs(groupID: Int64) async -> [WordGroupImageRef] {
        do {
            return try await db.dbQueue.read { db in
                guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return [] }
                return try WordGroupImageRef.fetchAll(
                    db,
                    sql: """
                    SELECT id,
                           group_id AS groupID,
                           file_name AS fileName,
                           asset_identifier AS assetIdentifier,
                           created_at AS createdAt
                    FROM word_group_images
                    WHERE group_id = ?
                    ORDER BY created_at ASC, id ASC
                    """,
                    arguments: [groupID]
                )
            }
        } catch {
            print("fetchWordGroupImageRefs error:", error)
            return []
        }
    }

    func appendWordGroupImages(groupID: Int64, images: [WordGroupImageInput]) async {
        let validImages = images.filter { !$0.imageData.isEmpty }
        guard !validImages.isEmpty else { return }

        do {
            let isRealGroup = try await db.dbQueue.read { db in
                try Self.isRealWordGroup(db: db, groupID: groupID)
            }
            guard isRealGroup else { return }

            let directoryURL = try wordGroupImagesDirectoryURL(groupID: groupID, createIfNeeded: true)

            try await db.dbQueue.write { db in
                for image in validImages {
                    if let assetIdentifier = image.assetIdentifier {
                        let alreadyExists = try Bool.fetchOne(
                            db,
                            sql: """
                            SELECT EXISTS(
                                SELECT 1
                                FROM word_group_images
                                WHERE group_id = ? AND asset_identifier = ?
                            )
                            """,
                            arguments: [groupID, assetIdentifier]
                        ) ?? false
                        if alreadyExists { continue }
                    }

                    let fileName = "\(UUID().uuidString).jpg"
                    let fileURL = directoryURL.appendingPathComponent(fileName)

                    do {
                        try image.imageData.write(to: fileURL, options: .atomic)
                        try db.execute(
                            sql: """
                            INSERT INTO word_group_images(group_id, file_name, asset_identifier)
                            VALUES (?, ?, ?)
                            """,
                            arguments: [groupID, fileName, image.assetIdentifier]
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: fileURL)
                        print("appendWordGroupImages item error:", error)
                    }
                }
            }
            await notifyLocalMutation()
        } catch {
            print("appendWordGroupImages error:", error)
        }
    }

    func loadWordGroupImageData(groupID: Int64, fileName: String) async -> Data? {
        do {
            let isRealGroup = try await db.dbQueue.read { db in
                try Self.isRealWordGroup(db: db, groupID: groupID)
            }
            guard isRealGroup else { return nil }
            let fileURL = try wordGroupImageFileURL(groupID: groupID, fileName: fileName)
            return try Data(contentsOf: fileURL)
        } catch {
            return nil
        }
    }

    func deleteWordGroupImage(imageID: Int64) async {
        do {
            let deletedImage: (groupID: Int64, fileName: String)? = try await db.dbQueue.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT group_id, file_name
                    FROM word_group_images
                    WHERE id = ?
                    """,
                    arguments: [imageID]
                ) else {
                    return nil
                }

                let groupID: Int64 = row["group_id"]
                let fileName: String = row["file_name"]

                try db.execute(
                    sql: "DELETE FROM word_group_images WHERE id = ?",
                    arguments: [imageID]
                )

                return (groupID, fileName)
            }

            guard let deletedImage else { return }

            let fileURL = try wordGroupImageFileURL(groupID: deletedImage.groupID, fileName: deletedImage.fileName)
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                    print("deleteWordGroupImage file remove error:", error)
                }
            }
            await notifyLocalMutation()
        } catch {
            print("deleteWordGroupImage error:", error)
        }
    }
    
    func fetchWords(inGroupID groupID: Int64) async -> [String] {
        do {
            return try await db.dbQueue.read { db in
                guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return [] }
                return try String.fetchAll(
                    db,
                    sql: """
                    SELECT word
                    FROM word_group_words
                    WHERE group_id = ?
                    ORDER BY created_at DESC, word ASC
                    """,
                    arguments: [groupID]
                )
            }
        } catch {
            print("fetchWords(inGroupID:) error:", error)
            return []
        }
    }
    
    func createWordGroup(baseName: String, words: [String]) async -> Int64? {
        let trimmedName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = trimmedName.isEmpty ? "New Group" : trimmedName

        do {
            let groupID = try await db.dbQueue.write { db in
                let finalName = try Self.uniqueWordGroupName(db: db, originalName: originalName)
                try db.execute(
                    sql: """
                    INSERT INTO word_groups(name, kind, parent_group_id)
                    VALUES(?, 'group', NULL)
                    """,
                    arguments: [finalName]
                )

                let groupID = db.lastInsertedRowID
                for word in Self.normalizedWords(words) {
                    try db.execute(
                        sql: """
                        INSERT INTO word_group_words(group_id, word)
                        VALUES (?, ?)
                        ON CONFLICT(group_id, word) DO NOTHING
                        """,
                        arguments: [groupID, word]
                    )
                }
                
                return groupID
            }
            await notifyLocalMutation()
            return groupID
        } catch {
            print("createWordGroup error:", error)
            return nil
        }
    }

    func createParentWordGroup(baseName: String) async -> Int64? {
        let trimmedName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = trimmedName.isEmpty ? "New Parent Group" : trimmedName

        do {
            let groupID = try await db.dbQueue.write { db in
                let finalName = try Self.uniqueWordGroupName(db: db, originalName: originalName)
                try db.execute(
                    sql: """
                    INSERT INTO word_groups(name, kind, parent_group_id)
                    VALUES(?, 'parent', NULL)
                    """,
                    arguments: [finalName]
                )
                return db.lastInsertedRowID
            }
            await notifyLocalMutation()
            return groupID
        } catch {
            print("createParentWordGroup error:", error)
            return nil
        }
    }

    func moveWordGroup(groupID: Int64, toParentGroupID parentGroupID: Int64) async -> Bool {
        do {
            let didMove = try await db.dbQueue.write { db in
                guard try Self.isUnarchivedRealWordGroup(db: db, groupID: groupID) else { return false }
                guard try Self.isUnarchivedParentWordGroup(db: db, groupID: parentGroupID) else { return false }

                try db.execute(
                    sql: """
                    UPDATE word_groups
                    SET parent_group_id = ?
                    WHERE id = ?
                    """,
                    arguments: [parentGroupID, groupID]
                )
                return db.changesCount > 0
            }
            if didMove {
                await notifyLocalMutation()
            }
            return didMove
        } catch {
            print("moveWordGroup error:", error)
            return false
        }
    }

    func deleteParentWordGroup(parentGroupID: Int64, preserveChildren: Bool) async {
        do {
            if preserveChildren {
                let didDelete = try await db.dbQueue.write { db in
                    guard try Self.isParentWordGroup(db: db, groupID: parentGroupID) else { return false }

                    try db.execute(
                        sql: """
                        UPDATE word_groups
                        SET parent_group_id = NULL
                        WHERE parent_group_id = ?
                        """,
                        arguments: [parentGroupID]
                    )
                    try db.execute(
                        sql: "DELETE FROM word_groups WHERE id = ?",
                        arguments: [parentGroupID]
                    )
                    return db.changesCount > 0
                }

                if didDelete {
                    await notifyLocalMutation()
                }
                return
            }

            let deletedGroups = try await db.dbQueue.write { db -> [DeletedWordGroupAssets] in
                guard try Self.isParentWordGroup(db: db, groupID: parentGroupID) else { return [] }

                let childGroupIDs = try Int64.fetchAll(
                    db,
                    sql: """
                    SELECT id
                    FROM word_groups
                    WHERE parent_group_id = ?
                      AND kind = 'group'
                    ORDER BY id ASC
                    """,
                    arguments: [parentGroupID]
                )

                var deletedGroups: [DeletedWordGroupAssets] = []
                deletedGroups.reserveCapacity(childGroupIDs.count)
                for childGroupID in childGroupIDs {
                    if let deletedGroup = try Self.deleteWordGroupAndPurgeCollections(db: db, groupID: childGroupID) {
                        deletedGroups.append(deletedGroup)
                    }
                }

                try db.execute(
                    sql: "DELETE FROM word_groups WHERE id = ?",
                    arguments: [parentGroupID]
                )

                return deletedGroups
            }

            removeDeletedWordGroupAssets(deletedGroups)
            await removeHiddenMarkForWordsNotInAnyGroup(nil)
            await notifyLocalMutation()
        } catch {
            print("deleteParentWordGroup error:", error)
        }
    }

    func addWord(_ word: String, toGroupID groupID: Int64) async {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        do {
            try await db.dbQueue.write { db in
                guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return }
                try db.execute(
                    sql: """
                    INSERT INTO word_group_words(group_id, word)
                    VALUES (?, ?)
                    ON CONFLICT(group_id, word) DO NOTHING
                    """,
                    arguments: [groupID, normalized]
                )
            }
            await notifyLocalMutation()
        } catch {
            print("addWord(toGroupID:) error:", error)
        }
    }
    
    func removeWord(_ word: String, fromGroupID groupID: Int64) async {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        do {
            try await db.dbQueue.write { db in
                guard try Self.isRealWordGroup(db: db, groupID: groupID) else { return }
                try db.execute(
                    sql: """
                    DELETE FROM word_group_words
                    WHERE group_id = ? AND word = ?
                    """,
                    arguments: [groupID, normalized]
                )
            }
            
            await removeHiddenMarkForWordsNotInAnyGroup([normalized])
            await notifyLocalMutation()
        } catch {
            print("removeWord(fromGroupID:) error:", error)
        }
    }
    
    func renameWordGroup(groupID: Int64, baseName: String) async -> String? {
        let trimmedName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = trimmedName.isEmpty ? "New Group" : trimmedName

        do {
            let finalName: String? = try await db.dbQueue.write { db in
                let exists = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM word_groups WHERE id = ?
                    )
                    """,
                    arguments: [groupID]
                ) ?? false
                
                guard exists else { return nil }

                let finalName = try Self.uniqueWordGroupName(
                    db: db,
                    originalName: originalName,
                    excludingGroupID: groupID
                )
                try db.execute(
                    sql: """
                    UPDATE word_groups
                    SET name = ?
                    WHERE id = ?
                    """,
                    arguments: [finalName, groupID]
                )
                
                return finalName
            }
            if finalName != nil {
                await notifyLocalMutation()
            }
            return finalName
        } catch {
            print("renameWordGroup error:", error)
            return nil
        }
    }
    
    func deleteWordGroupAndPurgeCollections(groupID: Int64) async {
        do {
            let deletedGroups = try await db.dbQueue.write { db in
                guard let deletedGroup = try Self.deleteWordGroupAndPurgeCollections(db: db, groupID: groupID) else {
                    return [DeletedWordGroupAssets]()
                }
                return [deletedGroup]
            }

            removeDeletedWordGroupAssets(deletedGroups)
            await removeHiddenMarkForWordsNotInAnyGroup(nil)
            await notifyLocalMutation()
        } catch {
            print("deleteWordGroupAndPurgeCollections error:", error)
        }
    }
    
    func fetchAllCollectionWordsForAddGroup() async -> [String] {
        do {
            return try await db.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    WITH all_words AS (
                        SELECT word FROM favorites
                        UNION
                        SELECT word FROM highlights
                        UNION
                        SELECT word FROM annotations
                    )
                    SELECT word
                    FROM all_words
                    WHERE word NOT IN (
                        SELECT word FROM collection_hidden_words
                    )
                    ORDER BY word ASC
                    """
                )
            }
        } catch {
            print("fetchAllCollectionWordsForAddGroup error:", error)
            return []
        }
    }
    
    func fetchHiddenWordsForCollections() async -> Set<String> {
        do {
            let rows = try await db.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT word
                    FROM collection_hidden_words
                    """
                )
            }
            return Set(rows)
        } catch {
            print("fetchHiddenWordsForCollections error:", error)
            return []
        }
    }
    
    func markWordsHiddenForCollections(_ words: [String]) async {
        let normalizedWords = Set(
            words
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        
        guard !normalizedWords.isEmpty else { return }
        
        do {
            try await db.dbQueue.write { db in
                for word in normalizedWords {
                    try db.execute(
                        sql: """
                        INSERT INTO collection_hidden_words(word)
                        VALUES (?)
                        ON CONFLICT(word) DO NOTHING
                        """,
                        arguments: [word]
                    )
                }
            }
            await notifyLocalMutation()
        } catch {
            print("markWordsHiddenForCollections error:", error)
        }
    }
    
    func removeHiddenMarkForWordsNotInAnyGroup(_ candidateWords: [String]?) async {
        do {
            try await db.dbQueue.write { db in
                if let candidateWords {
                    let normalizedWords = Set(
                        candidateWords
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    )
                    
                    for word in normalizedWords {
                        let stillInAnyGroup = try Bool.fetchOne(
                            db,
                            sql: """
                            SELECT EXISTS(
                                SELECT 1
                                FROM word_group_words
                                WHERE word = ?
                            )
                            """,
                            arguments: [word]
                        ) ?? false
                        
                        if !stillInAnyGroup {
                            try db.execute(
                                sql: """
                                DELETE FROM collection_hidden_words
                                WHERE word = ?
                                """,
                                arguments: [word]
                            )
                        }
                    }
                } else {
                    try db.execute(
                        sql: """
                        DELETE FROM collection_hidden_words
                        WHERE NOT EXISTS (
                            SELECT 1
                            FROM word_group_words
                            WHERE word_group_words.word = collection_hidden_words.word
                        )
                        """
                    )
                }
            }
            await notifyLocalMutation()
        } catch {
            print("removeHiddenMarkForWordsNotInAnyGroup error:", error)
        }
    }

    private func wordGroupImagesRootDirectoryURL(createIfNeeded: Bool) throws -> URL {
        try UserStoragePaths.localWordGroupImagesRootURL(createIfNeeded: createIfNeeded)
    }

    private func wordGroupImagesDirectoryURL(groupID: Int64, createIfNeeded: Bool) throws -> URL {
        let fm = FileManager.default
        let rootDirectory = try wordGroupImagesRootDirectoryURL(createIfNeeded: createIfNeeded)
        let groupDirectory = rootDirectory.appendingPathComponent("\(groupID)", isDirectory: true)
        if createIfNeeded, !fm.fileExists(atPath: groupDirectory.path) {
            try fm.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        }
        return groupDirectory
    }

    private func wordGroupImageFileURL(groupID: Int64, fileName: String) throws -> URL {
        try wordGroupImagesDirectoryURL(groupID: groupID, createIfNeeded: false)
            .appendingPathComponent(fileName, isDirectory: false)
    }
    
}
