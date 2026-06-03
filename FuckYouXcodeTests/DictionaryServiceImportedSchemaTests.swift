import Foundation
import GRDB
import Testing
@testable import FuckYouXcode

struct DictionaryServiceImportedSchemaTests {
    private func makeTempDBURL(name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(name)_\(UUID().uuidString).sqlite")
    }

    @Test func importedSchemaProvidesHTMLAndAssets() async throws {
        let dbURL = makeTempDBURL(name: "imported_schema")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
        }

        let queue = try DatabaseQueue(path: dbURL.path)
        try await queue.write { db in
            try db.execute(sql: """
            CREATE TABLE entries (
              id INTEGER PRIMARY KEY,
              word TEXT NOT NULL,
              lemma TEXT NOT NULL DEFAULT '',
              pos TEXT NOT NULL DEFAULT '',
              phonetic TEXT NOT NULL DEFAULT '',
              frequency INTEGER NOT NULL DEFAULT 0,
              level TEXT NOT NULL DEFAULT '',
              definition TEXT NOT NULL DEFAULT '',
              examples TEXT NOT NULL DEFAULT '',
              idioms TEXT NOT NULL DEFAULT '',
              origination TEXT NOT NULL DEFAULT '',
              hwd TEXT NOT NULL DEFAULT ''
            );
            """)

            try db.execute(sql: "CREATE TABLE lemma_map(form TEXT PRIMARY KEY, lemma TEXT NOT NULL) WITHOUT ROWID;")
            try db.execute(sql: "CREATE TABLE entry_html(entry_id INTEGER PRIMARY KEY, entry_key TEXT NOT NULL, html TEXT NOT NULL);")
            try db.execute(sql: "CREATE TABLE dictionary_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            try db.execute(sql: "CREATE TABLE mdd_asset_index(path_norm TEXT PRIMARY KEY, original_key TEXT NOT NULL, data BLOB NOT NULL, mime TEXT NOT NULL);")
            try db.execute(sql: "CREATE VIRTUAL TABLE entries_fts USING fts5(word, lemma, hwd, definition);")

            try db.execute(sql: "INSERT INTO dictionary_meta(key, value) VALUES ('strip_key', '0');")
            try db.execute(sql: "INSERT INTO dictionary_meta(key, value) VALUES ('key_case_sensitive', '0');")

            try db.execute(
                sql: """
                INSERT INTO entries(id, word, lemma, pos, definition)
                VALUES (1, 'run', 'run', 'verb', 'to move quickly')
                """
            )
            try db.execute(sql: "INSERT INTO entry_html(entry_id, entry_key, html) VALUES (1, 'run', '<div class=\"entry\">Run HTML</div>');")
            try db.execute(sql: "INSERT INTO lemma_map(form, lemma) VALUES ('running', 'run');")
            try db.execute(sql: "INSERT INTO entries_fts(rowid, word, lemma, hwd, definition) VALUES (1, 'run', 'run', '', 'to move quickly');")

            try db.execute(
                sql: "INSERT INTO mdd_asset_index(path_norm, original_key, data, mime) VALUES (?, ?, ?, ?)",
                arguments: ["css/main.css", "CSS/Main.CSS", Data("body{}".utf8), "text/css"]
            )
        }

        let service = try DictionaryService(dbQueue: queue)
        let entries = try await service.lookupEntries("running")

        #expect(entries.contains(where: { $0.word == "run" }))
        #expect(entries.first(where: { $0.word == "run" })?.html?.contains("Run HTML") == true)

        let html = try service.fetchEntryHTML(entryKey: "RUN")
        #expect(html?.contains("Run HTML") == true)

        let exactAsset = try service.fetchAsset(path: "CSS/Main.CSS")
        #expect(exactAsset?.mimeType == "text/css")
        #expect(exactAsset?.data == Data("body{}".utf8))

        let foldedAsset = try service.fetchAsset(path: "css/main.css")
        #expect(foldedAsset?.originalKey == "CSS/Main.CSS")

        let windowsStyleAsset = try service.fetchAsset(path: #"CSS\Main.CSS"#)
        #expect(windowsStyleAsset?.originalKey == "CSS/Main.CSS")

        let suggestions = try await service.suggestions("ru", limit: 5)
        #expect(suggestions.contains("run"))

        let fallbackEntries = try await service.lookupEntries("ru")
        #expect(fallbackEntries.first?.word == "run")

        let exactOnlyEntries = try await service.lookupEntries("ru", allowsFallbacks: false)
        #expect(exactOnlyEntries.isEmpty)
    }

    @Test func fetchEntryHTMLResolvesLinksAndStopsCycles() throws {
        let dbURL = makeTempDBURL(name: "imported_schema_links")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
        }

        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE entries (
              id INTEGER PRIMARY KEY,
              word TEXT NOT NULL,
              lemma TEXT NOT NULL DEFAULT '',
              pos TEXT NOT NULL DEFAULT '',
              phonetic TEXT NOT NULL DEFAULT '',
              frequency INTEGER NOT NULL DEFAULT 0,
              level TEXT NOT NULL DEFAULT '',
              definition TEXT NOT NULL DEFAULT '',
              examples TEXT NOT NULL DEFAULT '',
              idioms TEXT NOT NULL DEFAULT '',
              origination TEXT NOT NULL DEFAULT '',
              hwd TEXT NOT NULL DEFAULT ''
            );
            """)
            try db.execute(sql: "CREATE TABLE lemma_map(form TEXT PRIMARY KEY, lemma TEXT NOT NULL) WITHOUT ROWID;")
            try db.execute(sql: "CREATE TABLE entry_html(entry_id INTEGER PRIMARY KEY, entry_key TEXT NOT NULL, html TEXT NOT NULL);")
            try db.execute(sql: "CREATE TABLE dictionary_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            try db.execute(sql: "INSERT INTO dictionary_meta(key, value) VALUES ('strip_key', '0');")
            try db.execute(sql: "INSERT INTO dictionary_meta(key, value) VALUES ('key_case_sensitive', '0');")

            try db.execute(sql: "INSERT INTO entries(id, word, lemma, definition) VALUES (1, 'a', 'a', 'a');")
            try db.execute(sql: "INSERT INTO entry_html(entry_id, entry_key, html) VALUES (1, 'a', '@@@LINK=b');")
            try db.execute(sql: "INSERT INTO entries(id, word, lemma, definition) VALUES (2, 'b', 'b', 'b');")
            try db.execute(sql: "INSERT INTO entry_html(entry_id, entry_key, html) VALUES (2, 'b', '<div>Target HTML</div>');")

            try db.execute(sql: "INSERT INTO entries(id, word, lemma, definition) VALUES (3, 'c1', 'c1', 'c1');")
            try db.execute(sql: "INSERT INTO entry_html(entry_id, entry_key, html) VALUES (3, 'c1', '@@@LINK=c2');")
            try db.execute(sql: "INSERT INTO entries(id, word, lemma, definition) VALUES (4, 'c2', 'c2', 'c2');")
            try db.execute(sql: "INSERT INTO entry_html(entry_id, entry_key, html) VALUES (4, 'c2', '@@@LINK=c1');")
        }

        let service = try DictionaryService(dbQueue: queue)
        let resolved = try service.fetchEntryHTML(entryKey: "a")
        #expect(resolved?.contains("Target HTML") == true)

        let cycle = try service.fetchEntryHTML(entryKey: "c1")
        #expect(cycle?.hasPrefix("@@@LINK=") == true)
    }

    @Test func baseSchemaStillWorksWithoutEntryHTML() async throws {
        let dbURL = makeTempDBURL(name: "base_schema")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
        }

        let queue = try DatabaseQueue(path: dbURL.path)
        try await queue.write { db in
            try db.execute(sql: """
            CREATE TABLE entries (
              id INTEGER PRIMARY KEY,
              word TEXT NOT NULL,
              lemma TEXT NOT NULL DEFAULT '',
              pos TEXT NOT NULL DEFAULT '',
              phonetic TEXT NOT NULL DEFAULT '',
              frequency INTEGER NOT NULL DEFAULT 0,
              level TEXT NOT NULL DEFAULT '',
              definition TEXT NOT NULL DEFAULT '',
              examples TEXT NOT NULL DEFAULT '',
              idioms TEXT NOT NULL DEFAULT '',
              origination TEXT NOT NULL DEFAULT '',
              hwd TEXT NOT NULL DEFAULT ''
            );
            """)
            try db.execute(sql: "INSERT INTO entries(id, word, lemma, pos, definition) VALUES (1, 'alpha', 'alpha', 'noun', 'first');")
        }

        let service = try DictionaryService(dbQueue: queue)
        let entries = try await service.lookupEntries("alpha")
        #expect(entries.first?.word == "alpha")
        #expect(entries.first?.html == nil)
    }

    @Test func chineseMeaningSearchReturnsEnglishEntries() async throws {
        let dbURL = makeTempDBURL(name: "chinese_meaning")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
        }

        let queue = try DatabaseQueue(path: dbURL.path)
        try await queue.write { db in
            try db.execute(sql: """
            CREATE TABLE entries (
              id INTEGER PRIMARY KEY,
              word TEXT NOT NULL,
              lemma TEXT NOT NULL DEFAULT '',
              pos TEXT NOT NULL DEFAULT '',
              phonetic TEXT NOT NULL DEFAULT '',
              frequency INTEGER NOT NULL DEFAULT 0,
              level TEXT NOT NULL DEFAULT '',
              definition TEXT NOT NULL DEFAULT '',
              examples TEXT NOT NULL DEFAULT '',
              idioms TEXT NOT NULL DEFAULT '',
              origination TEXT NOT NULL DEFAULT '',
              hwd TEXT NOT NULL DEFAULT ''
            );
            """)
            try db.execute(sql: "INSERT INTO entries(id, word, lemma, pos, frequency, definition) VALUES (1, 'apple', 'apple', 'noun', 5, '1. 苹果 (a fruit)');")
            try db.execute(sql: "INSERT INTO entries(id, word, lemma, pos, frequency, definition) VALUES (2, 'cider', 'cider', 'noun', 2, '1. 苹果酒 (an alcoholic drink)');")
            try db.execute(sql: "INSERT INTO entries(id, word, lemma, pos, frequency, definition) VALUES (3, 'book', 'book', 'noun', 5, '1. 书 (a written work)');")
        }

        let service = try DictionaryService(dbQueue: queue)

        let suggestions = try await service.suggestions("苹果", limit: 5)
        #expect(suggestions.first == "apple")
        #expect(suggestions.contains("cider"))
        #expect(!suggestions.contains("book"))

        let entries = try await service.lookupEntries("苹果")
        #expect(entries.first?.word == "apple")
    }
}
