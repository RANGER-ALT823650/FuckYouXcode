//
//  DictionaryService.swift
//  LearningThroughVideos
//
//  Created by 马逸凡 on 2026/2/5.
//
import Foundation
import GRDB

nonisolated struct DictionaryNormalizationProfile: Equatable, Sendable {
    let stripKey: Bool
    let keyCaseSensitive: Bool

    func normalizeForLookup(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let stripped: String
        if stripKey {
            stripped = Self.stripDecorations(from: trimmed)
        } else {
            stripped = trimmed
        }

        let cased = keyCaseSensitive ? stripped : stripped.lowercased()
        return cased.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripDecorations(from value: String) -> String {
        value.replacingOccurrences(
            of: "[\\p{P}\\p{S}\\s_]+",
            with: "",
            options: .regularExpression
        )
    }
}

nonisolated struct DictionaryEntry: Identifiable, FetchableRecord, Sendable {
    let id: Int64
    let word: String
    let lemma: String?
    let definition: String?
    let phonetic: String?
    let pos: String?
    let frequency: Int64?
    let examples: String?
    let level: String?
    let idioms: String?
    let origination: String?
    let hwd: String?
    let html: String?

    init(row: Row) {
        id = row["id"]
        word = row["word"] ?? ""
        lemma = row["lemma"]
        definition = row["definition"]
        phonetic = row["phonetic"]
        pos = row["pos"]
        frequency = row["frequency"]
        examples = row["examples"]
        level = row["level"]
        idioms = row["idioms"]
        origination = row["origination"]
        hwd = row["hwd"]
        html = row["html"]
    }
}

nonisolated struct DictionaryAssetBlob: Sendable {
    let originalKey: String
    let mimeType: String
    let data: Data
}

nonisolated struct WordMetaRaw: Sendable {
    let frequency: Int64?
    let level: String?
}

nonisolated struct WordListPreviewRaw: Sendable {
    enum POSStyle {
        case abbreviation
    }

    let pos: String?
    let definition: String?
}

extension WordListPreviewRaw {
    func compactPreviewText(posStyle: POSStyle = .abbreviation) -> String? {
        let compactPOS = compactPOSText(style: posStyle)
        let compactDefinition = compactDefinitionText()

        switch (compactPOS, compactDefinition) {
        case let (pos?, definition?):
            return "\(pos) \(definition)"
        case let (pos?, nil):
            return pos
        case let (nil, definition?):
            return definition
        case (nil, nil):
            return nil
        }
    }

    private func compactPOSText(style: POSStyle) -> String? {
        guard let pos else { return nil }
        let normalized = pos
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !normalized.isEmpty else { return nil }

        switch style {
        case .abbreviation:
            return Self.abbreviation(for: normalized)
        }
    }

    private func compactDefinitionText() -> String? {
        guard let definition else { return nil }
        let normalized = definition
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.isEmpty ? nil : normalized
    }

    private static func abbreviation(for rawPOS: String) -> String {
        let raw = rawPOS.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return raw }

        let primary = raw
            .components(separatedBy: CharacterSet(charactersIn: ",/;|"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch primary {
        case "noun", "n", "n.":
            return "n."
        case "verb", "v", "v.":
            return "v."
        case "adjective", "adj", "adj.":
            return "adj."
        case "adverb", "adv", "adv.":
            return "adv."
        case "pronoun", "pron", "pron.":
            return "pron."
        case "preposition", "prep", "prep.":
            return "prep."
        case "conjunction", "conj", "conj.":
            return "conj."
        case "interjection", "interj", "interj.":
            return "interj."
        case "determiner", "det", "det.":
            return "det."
        case "numeral", "num", "num.":
            return "num."
        case "phrase", "phr", "phr.", "phrasal verb":
            return "phr."
        default:
            return raw
        }
    }
}

nonisolated struct DictionaryCapabilities: Sendable {
    let hasLemmaMap: Bool
    let hasFTS: Bool
    let hasEntryHTML: Bool
    let hasMDDAssetIndex: Bool
}

extension WordListPreviewRaw.POSStyle: Sendable {}

nonisolated final class DictionaryService: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let dictionaryCapabilities: DictionaryCapabilities
    private let normalizationProfile: DictionaryNormalizationProfile

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue

        var capabilities: DictionaryCapabilities?
        var profile: DictionaryNormalizationProfile?

        try dbQueue.read { db in
            capabilities = try Self.loadCapabilities(db: db)
            profile = try Self.loadNormalizationProfile(db: db)
        }

        guard let capabilities else {
            throw NSError(
                domain: "DictionaryService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "词典能力探测失败"]
            )
        }
        guard let profile else {
            throw NSError(
                domain: "DictionaryService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "词典归一化配置加载失败"]
            )
        }

        self.dictionaryCapabilities = capabilities
        self.normalizationProfile = profile
    }

    func capabilities() -> DictionaryCapabilities {
        dictionaryCapabilities
    }

    func currentNormalizationProfile() -> DictionaryNormalizationProfile {
        normalizationProfile
    }

    func supportsHTMLRendering() -> Bool {
        dictionaryCapabilities.hasEntryHTML
    }

    func supportsMDDAssetLookup() -> Bool {
        dictionaryCapabilities.hasMDDAssetIndex
    }

    // MARK: - Public API

    /// 查词：返回「输入词本身」+「lemma 词头」（如果存在）
    /// - 例：ran -> [ran, run]（不会扩展出 running / went）
    func lookup(_ rawInput: String) async throws -> [DictionaryEntry] {
        try await lookupEntries(rawInput)
    }

    /// 查词：返回「输入词本身」+「lemma 词头」（如果存在）。
    /// 允许 fallback 时，会继续尝试 FTS 最佳匹配或中文释义搜索。
    func lookupEntries(_ rawInput: String, allowsFallbacks: Bool = true) async throws -> [DictionaryEntry] {
        let form = normalize(rawInput)
        guard !form.isEmpty else { return [] }
        let shouldSearchMeaning = Self.containsCJK(form)

        return try await dbQueue.read { db in
            var results: [DictionaryEntry] = []
            var seen = Set<Int64>()

            let formEntries = try fetchExactWords(form, db: db)
            for entry in formEntries where seen.insert(entry.id).inserted {
                results.append(entry)
            }

            if dictionaryCapabilities.hasLemmaMap,
               let lemma = try resolveLemmaIfNeeded(form, db: db),
               lemma != form {
                let lemmaEntries = try fetchExactWords(lemma, db: db)
                for entry in lemmaEntries where seen.insert(entry.id).inserted {
                    results.append(entry)
                }
            }

            if allowsFallbacks,
               results.isEmpty,
               dictionaryCapabilities.hasFTS,
               let best = try fetchBestByFTS(form, db: db) {
                results.append(best)
            }

            if allowsFallbacks, results.isEmpty, shouldSearchMeaning {
                let meaningEntries = try fetchEntriesByMeaning(form, limit: 12, db: db)
                for entry in meaningEntries where seen.insert(entry.id).inserted {
                    results.append(entry)
                }
            }

            return results
        }
    }

    /// 联想建议：prefix 搜索（auto -> automatic）
    func suggestions(_ rawInput: String, limit: Int = 20) async throws -> [String] {
        let form = normalize(rawInput)
        guard !form.isEmpty else { return [] }

        return try await dbQueue.read { db in
            if Self.containsCJK(form) {
                return try fetchMeaningSuggestions(form, limit: limit, db: db)
            }

            if dictionaryCapabilities.hasFTS {
                let query = "word:\(escapeFTS(form))*"
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT word
                    FROM entries_fts
                    WHERE entries_fts MATCH ?
                    LIMIT ?
                    """,
                    arguments: [query, limit]
                )
                return rows.compactMap { $0["word"] as String? }
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT word
                FROM entries
                WHERE word LIKE ?
                LIMIT ?
                """,
                arguments: ["\(form)%", limit]
            )
            return rows.compactMap { $0["word"] as String? }
        }
    }

    func fetchEntryHTML(entryKey: String) throws -> String? {
        guard dictionaryCapabilities.hasEntryHTML else { return nil }
        let maxLinkDepth = 8

        return try dbQueue.read { db in
            var visited: Set<String> = []

            func resolveHTML(for key: String, depth: Int) throws -> String? {
                guard let html = try self.fetchRawEntryHTML(entryKey: key, db: db) else {
                    return nil
                }

                guard let target = self.linkTarget(from: html) else {
                    return html
                }

                guard depth < maxLinkDepth else {
                    return html
                }

                let identity = self.lookupIdentity(for: target)
                guard !identity.isEmpty else {
                    return html
                }
                guard visited.insert(identity).inserted else {
                    return html
                }

                return try resolveHTML(for: target, depth: depth + 1) ?? html
            }

            let startIdentity = self.lookupIdentity(for: entryKey)
            if !startIdentity.isEmpty {
                _ = visited.insert(startIdentity)
            }

            return try resolveHTML(for: entryKey, depth: 0)
        }
    }

    func fetchAsset(path rawPath: String) throws -> DictionaryAssetBlob? {
        guard dictionaryCapabilities.hasMDDAssetIndex else { return nil }

        let canonical = MDictResourcePath.canonicalPath(rawPath)
        guard !canonical.isEmpty else { return nil }

        let normalized = MDictResourcePath.normalizedLookupPath(canonical)

        return try dbQueue.read { db in
            if let exact = try Row.fetchOne(
                db,
                sql: """
                SELECT original_key, mime, data
                FROM mdd_asset_index
                WHERE original_key = ?
                LIMIT 1
                """,
                arguments: [canonical]
            ) {
                return DictionaryAssetBlob(
                    originalKey: exact["original_key"] ?? canonical,
                    mimeType: exact["mime"] ?? "application/octet-stream",
                    data: exact["data"] ?? Data()
                )
            }

            if let insensitive = try Row.fetchOne(
                db,
                sql: """
                SELECT original_key, mime, data
                FROM mdd_asset_index
                WHERE path_norm = ?
                LIMIT 1
                """,
                arguments: [normalized]
            ) {
                return DictionaryAssetBlob(
                    originalKey: insensitive["original_key"] ?? canonical,
                    mimeType: insensitive["mime"] ?? "application/octet-stream",
                    data: insensitive["data"] ?? Data()
                )
            }

            return nil
        }
    }

    func fetchWordMeta(words: [String]) throws -> [String: WordMetaRaw] {
        let normalized = Array(
            Set(
                words
                    .map { normalize($0) }
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalized.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: normalized.count).joined(separator: ",")
        let sql = """
        SELECT word,
               MAX(frequency) AS frequency,
               GROUP_CONCAT(level, '|') AS level
        FROM entries
        WHERE word IN (\(placeholders))
        GROUP BY word
        """

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(normalized))
            var result: [String: WordMetaRaw] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                guard let word: String = row["word"] else { continue }
                let freq: Int64? = row["frequency"]
                let level: String? = row["level"]
                result[word] = WordMetaRaw(frequency: freq, level: level)
            }
            return result
        }
    }

    func fetchWordListPreviews(words: [String]) async throws -> [String: WordListPreviewRaw] {
        let normalizedPairs = words.compactMap { word -> (original: String, normalized: String)? in
            let normalized = normalize(word)
            guard !normalized.isEmpty else { return nil }
            return (original: word, normalized: normalized)
        }
        guard !normalizedPairs.isEmpty else { return [:] }

        var originalsByNormalized: [String: [String]] = [:]
        originalsByNormalized.reserveCapacity(normalizedPairs.count)
        for pair in normalizedPairs {
            originalsByNormalized[pair.normalized, default: []].append(pair.original)
        }
        let normalizedWords = Array(originalsByNormalized.keys)
        let originalsByNormalizedSnapshot = originalsByNormalized

        return try await dbQueue.read { db in
            var previewByNormalized: [String: WordListPreviewRaw] = [:]
            previewByNormalized.reserveCapacity(normalizedWords.count)

            for chunk in normalizedWords.chunked(into: 200) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT word, pos, definition, id
                    FROM entries
                    WHERE word COLLATE NOCASE IN (\(placeholders))
                    ORDER BY
                      CASE pos
                        WHEN 'verb' THEN 1
                        WHEN 'noun' THEN 2
                        WHEN 'adjective' THEN 3
                        WHEN 'adverb' THEN 4
                        WHEN 'pronoun' THEN 5
                        WHEN 'preposition' THEN 6
                        WHEN 'conjunction' THEN 7
                        WHEN 'interjection' THEN 8
                        WHEN 'determiner' THEN 9
                        WHEN 'numeral' THEN 10
                        WHEN 'phrase' THEN 11
                        WHEN 'other' THEN 12
                        ELSE 99
                      END,
                      id ASC
                    """,
                    arguments: StatementArguments(chunk)
                )

                for row in rows {
                    guard let matchedWord: String = row["word"] else { continue }
                    let normalizedWord = normalize(matchedWord)
                    guard !normalizedWord.isEmpty else { continue }
                    guard previewByNormalized[normalizedWord] == nil else { continue }

                    previewByNormalized[normalizedWord] = WordListPreviewRaw(
                        pos: row["pos"],
                        definition: row["definition"]
                    )
                }
            }

            if dictionaryCapabilities.hasLemmaMap {
                let missingForms = normalizedWords.filter { previewByNormalized[$0] == nil }
                for chunk in missingForms.chunked(into: 200) {
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT lm.form AS form, e.pos AS pos, e.definition AS definition, e.id AS id
                        FROM lemma_map lm
                        JOIN entries e ON e.word = lm.lemma COLLATE NOCASE
                        WHERE lm.form IN (\(placeholders))
                        ORDER BY
                          lm.form ASC,
                          CASE e.pos
                            WHEN 'verb' THEN 1
                            WHEN 'noun' THEN 2
                            WHEN 'adjective' THEN 3
                            WHEN 'adverb' THEN 4
                            WHEN 'pronoun' THEN 5
                            WHEN 'preposition' THEN 6
                            WHEN 'conjunction' THEN 7
                            WHEN 'interjection' THEN 8
                            WHEN 'determiner' THEN 9
                            WHEN 'numeral' THEN 10
                            WHEN 'phrase' THEN 11
                            WHEN 'other' THEN 12
                            ELSE 99
                          END,
                          e.id ASC
                        """,
                        arguments: StatementArguments(chunk)
                    )

                    for row in rows {
                        guard let form: String = row["form"] else { continue }
                        guard previewByNormalized[form] == nil else { continue }

                        previewByNormalized[form] = WordListPreviewRaw(
                            pos: row["pos"],
                            definition: row["definition"]
                        )
                    }
                }
            }

            var result: [String: WordListPreviewRaw] = [:]
            result.reserveCapacity(words.count)
            for (normalizedWord, originals) in originalsByNormalizedSnapshot {
                guard let preview = previewByNormalized[normalizedWord] else { continue }
                for original in originals {
                    result[original] = preview
                }
            }
            return result
        }
    }

    // MARK: - Helpers

    private static func loadCapabilities(db: Database) throws -> DictionaryCapabilities {
        let hasLemmaMapTable = try db.tableExists("lemma_map")
        let hasFTSTable = try db.tableExists("entries_fts")
        let hasEntryHTMLTable = try db.tableExists("entry_html")
        let hasMDDAssetIndex = try db.tableExists("mdd_asset_index")

        return DictionaryCapabilities(
            hasLemmaMap: hasLemmaMapTable,
            hasFTS: hasFTSTable,
            hasEntryHTML: hasEntryHTMLTable,
            hasMDDAssetIndex: hasMDDAssetIndex
        )
    }

    private static func loadNormalizationProfile(db: Database) throws -> DictionaryNormalizationProfile {
        guard try db.tableExists("dictionary_meta") else {
            return DictionaryNormalizationProfile(stripKey: false, keyCaseSensitive: false)
        }

        let stripRaw = try String.fetchOne(
            db,
            sql: "SELECT value FROM dictionary_meta WHERE key = 'strip_key' LIMIT 1"
        )
        let caseRaw = try String.fetchOne(
            db,
            sql: "SELECT value FROM dictionary_meta WHERE key = 'key_case_sensitive' LIMIT 1"
        )

        return DictionaryNormalizationProfile(
            stripKey: boolValue(from: stripRaw),
            keyCaseSensitive: boolValue(from: caseRaw)
        )
    }

    private static func boolValue(from value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private func normalize(_ value: String) -> String {
        normalizationProfile.normalizeForLookup(value)
    }

    private func resolveLemmaIfNeeded(_ form: String, db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT lemma FROM lemma_map WHERE form = ? LIMIT 1",
            arguments: [form]
        )
    }

    private func fetchRawEntryHTML(entryKey: String, db: Database) throws -> String? {
        if let exact = try String.fetchOne(
            db,
            sql: """
            SELECT h.html
            FROM entry_html h
            WHERE h.entry_key = ? COLLATE NOCASE
            LIMIT 1
            """,
            arguments: [entryKey]
        ) {
            return exact
        }

        if let byWord = try String.fetchOne(
            db,
            sql: """
            SELECT h.html
            FROM entry_html h
            JOIN entries e ON e.id = h.entry_id
            WHERE e.word = ? COLLATE NOCASE
            LIMIT 1
            """,
            arguments: [entryKey]
        ) {
            return byWord
        }

        let normalized = normalize(entryKey)
        if normalized != entryKey,
           let byNormalized = try String.fetchOne(
            db,
            sql: """
            SELECT h.html
            FROM entry_html h
            JOIN entries e ON e.id = h.entry_id
            WHERE e.word = ? COLLATE NOCASE
            LIMIT 1
            """,
            arguments: [normalized]
           ) {
            return byNormalized
        }

        return nil
    }

    private func linkTarget(from html: String) -> String? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@@@LINK=") else {
            return nil
        }

        let target = String(trimmed.dropFirst("@@@LINK=".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    private func lookupIdentity(for key: String) -> String {
        let normalized = normalize(key)
        if !normalized.isEmpty {
            return normalized
        }

        return key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func fetchExactWords(_ word: String, db: Database) throws -> [DictionaryEntry] {
        let selectColumns = """
        e.id,
        e.word,
        e.lemma,
        e.pos,
        e.phonetic,
        e.frequency,
        e.level,
        e.definition,
        e.examples,
        e.idioms,
        e.origination,
        e.hwd,
        \(dictionaryCapabilities.hasEntryHTML ? "h.html AS html" : "NULL AS html")
        """

        let fromClause: String
        if dictionaryCapabilities.hasEntryHTML {
            fromClause = "entries e LEFT JOIN entry_html h ON h.entry_id = e.id"
        } else {
            fromClause = "entries e"
        }

        return try DictionaryEntry.fetchAll(
            db,
            sql: """
            SELECT \(selectColumns)
            FROM \(fromClause)
            WHERE e.word = ? COLLATE NOCASE
            ORDER BY
              CASE e.pos
                WHEN 'verb' THEN 1
                WHEN 'noun' THEN 2
                WHEN 'adjective' THEN 3
                WHEN 'adverb' THEN 4
                WHEN 'pronoun' THEN 5
                WHEN 'preposition' THEN 6
                WHEN 'conjunction' THEN 7
                WHEN 'interjection' THEN 8
                WHEN 'determiner' THEN 9
                WHEN 'numeral' THEN 10
                WHEN 'phrase' THEN 11
                WHEN 'other' THEN 12
                ELSE 99
              END,
              e.id ASC
            """,
            arguments: [word]
        )
    }

    private func fetchBestByFTS(_ word: String, db: Database) throws -> DictionaryEntry? {
        guard dictionaryCapabilities.hasFTS else { return nil }

        let query = "word:\(escapeFTS(word))*"

        let selectColumns = """
        e.id,
        e.word,
        e.lemma,
        e.definition,
        e.phonetic,
        e.pos,
        e.frequency,
        e.examples,
        e.level,
        e.idioms,
        e.origination,
        e.hwd,
        \(dictionaryCapabilities.hasEntryHTML ? "h.html AS html" : "NULL AS html")
        """

        let joinClause = dictionaryCapabilities.hasEntryHTML
            ? "LEFT JOIN entry_html h ON h.entry_id = e.id"
            : ""

        return try DictionaryEntry.fetchOne(
            db,
            sql: """
            SELECT \(selectColumns)
            FROM entries_fts f
            JOIN entries e ON e.id = f.rowid
            \(joinClause)
            WHERE entries_fts MATCH ?
            LIMIT 1
            """,
            arguments: [query]
        )
    }

    private func fetchEntriesByMeaning(_ term: String, limit: Int, db: Database) throws -> [DictionaryEntry] {
        let selectColumns = """
        e.id,
        e.word,
        e.lemma,
        e.definition,
        e.phonetic,
        e.pos,
        e.frequency,
        e.examples,
        e.level,
        e.idioms,
        e.origination,
        e.hwd,
        \(dictionaryCapabilities.hasEntryHTML ? "h.html AS html" : "NULL AS html")
        """

        let joinClause = dictionaryCapabilities.hasEntryHTML
            ? "LEFT JOIN entry_html h ON h.entry_id = e.id"
            : ""

        let arguments = meaningSearchArguments(for: term, limit: limit)

        return try DictionaryEntry.fetchAll(
            db,
            sql: """
            SELECT \(selectColumns)
            FROM entries e
            \(joinClause)
            WHERE e.definition LIKE ? ESCAPE '\\'
               OR e.idioms LIKE ? ESCAPE '\\'
            ORDER BY \(meaningSearchOrderSQL),
              e.id ASC
            LIMIT ?
            """,
            arguments: arguments
        )
    }

    private func fetchMeaningSuggestions(_ term: String, limit: Int, db: Database) throws -> [String] {
        let arguments = meaningSuggestionArguments(for: term, limit: limit)
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT e.word,
                   MAX(e.frequency) AS frequency,
                   MIN(length(e.word)) AS word_length,
                   MIN(\(meaningSearchOrderSQL)) AS meaning_rank
            FROM entries e
            WHERE e.definition LIKE ? ESCAPE '\\'
               OR e.idioms LIKE ? ESCAPE '\\'
            GROUP BY e.word
            ORDER BY
              meaning_rank ASC,
              frequency DESC,
              word_length ASC,
              e.word COLLATE NOCASE ASC
            LIMIT ?
            """,
            arguments: arguments
        )
        return rows.compactMap { $0["word"] as String? }
    }

    private var meaningSearchOrderSQL: String {
        """
        CASE
          WHEN e.definition LIKE ? ESCAPE '\\' THEN 0
          WHEN e.definition LIKE ? ESCAPE '\\' THEN 1
          WHEN e.definition LIKE ? ESCAPE '\\' THEN 2
          WHEN e.idioms LIKE ? ESCAPE '\\' THEN 3
          ELSE 4
        END
        """
    }

    private func meaningSearchArguments(for term: String, limit: Int) -> StatementArguments {
        let escapedTerm = Self.escapedLIKEPattern(term)
        return StatementArguments([
            "%\(escapedTerm)%",
            "%\(escapedTerm)%",
            "1. \(escapedTerm)%",
            "%\n%. \(escapedTerm)%",
            "%\(escapedTerm)%",
            "%\(escapedTerm)%",
            limit
        ])
    }

    private func meaningSuggestionArguments(for term: String, limit: Int) -> StatementArguments {
        let escapedTerm = Self.escapedLIKEPattern(term)
        return StatementArguments([
            "1. \(escapedTerm)%",
            "%\n%. \(escapedTerm)%",
            "%\(escapedTerm)%",
            "%\(escapedTerm)%",
            "%\(escapedTerm)%",
            "%\(escapedTerm)%",
            limit
        ])
    }

    private func escapeFTS(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "")
    }

    private static func escapedLIKEPattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2A6DF,
                 0x2A700...0x2B73F,
                 0x2B740...0x2B81F,
                 0x2B820...0x2CEAF:
                return true
            default:
                return false
            }
        }
    }
}

private extension Database {
    nonisolated func tableExists(_ name: String) throws -> Bool {
        try String.fetchOne(
            self,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name = ?;",
            arguments: [name]
        ) != nil
    }
}

private extension Array {
    nonisolated func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)
        var index = startIndex
        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }
        return result
    }
}
