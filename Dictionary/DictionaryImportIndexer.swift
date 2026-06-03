import Foundation
import GRDB

struct DictionaryPackageLayout {
    let mdxRelativePath: String
    let mddRelativePaths: [String]
    let mdxURL: URL
    let mddURLs: [URL]

    var mddRelativePath: String? {
        mddRelativePaths.first
    }

    var mddURL: URL? {
        mddURLs.first
    }

    func rebased(to sourceFolderURL: URL) -> DictionaryPackageLayout {
        DictionaryPackageLayout(
            mdxRelativePath: mdxRelativePath,
            mddRelativePaths: mddRelativePaths,
            mdxURL: sourceFolderURL.appendingPathComponent(mdxRelativePath, isDirectory: false),
            mddURLs: mddRelativePaths.map { sourceFolderURL.appendingPathComponent($0, isDirectory: false) }
        )
    }
}

struct DictionaryIndexResult {
    let dictionaryID: String
    let displayName: String
    let dbURL: URL
    let sourceFolderURL: URL
    let mdxRelativePath: String
    let mddRelativePath: String?
    let mddImportStats: MDDImportStats
    let entryCount: Int
    let profile: DictionaryNormalizationProfile
}

struct MDDImportStats: Equatable {
    let scannedFileCount: Int
    let importedFileCount: Int
    let assetCount: Int
    let skippedReasons: [String]

    var hasAssets: Bool {
        assetCount > 0
    }

    var warningMessage: String? {
        if scannedFileCount == 0 {
            return nil
        }

        if assetCount == 0 {
            if skippedReasons.isEmpty {
                return "检测到 MDD 文件但未导入可用资源，CSS/JS 等资源可能无法加载。"
            }
            return "检测到 MDD 文件但未导入可用资源：\(skippedReasons.joined(separator: "；"))"
        }

        guard !skippedReasons.isEmpty else {
            return nil
        }

        return "部分 MDD 文件未导入：\(skippedReasons.joined(separator: "；"))"
    }

    static let empty = MDDImportStats(
        scannedFileCount: 0,
        importedFileCount: 0,
        assetCount: 0,
        skippedReasons: []
    )
}

private enum DictionaryImportError: LocalizedError {
    case unreadableDirectory
    case noMDX
    case multipleMDX
    case ambiguousMDD
    case containsSymbolicLink(String)

    var errorDescription: String? {
        switch self {
        case .unreadableDirectory:
            return "无法访问所选目录，请确认文件权限后重试"
        case .noMDX:
            return "所选目录未检测到 .mdx 文件"
        case .multipleMDX:
            return "导入目录必须且仅能包含一个 .mdx 文件"
        case .ambiguousMDD:
            return "检测到多个 .mdd 且无法唯一匹配，请仅保留一个或使用与 mdx 同名文件"
        case let .containsSymbolicLink(path):
            return "导入目录包含符号链接（\(path)），为安全起见已拒绝导入"
        }
    }
}

private struct IndexBuildSummary {
    let entryCount: Int
    let profile: DictionaryNormalizationProfile
    let header: [String: String]
    let mddImportStats: MDDImportStats
}

private enum DictionaryImportTuning {
    static let entryBatchSize = 800
    static let mddAssetBatchSize = 200
    static let maxReportedSkipReasons = 8
    static let maxSingleMDDBytes: Int64 = 128 * 1024 * 1024
    static let maxTotalMDDBytes: Int64 = 256 * 1024 * 1024
}

final class DictionaryImportIndexer {
    static let shared = DictionaryImportIndexer()

    private let mdxParser = MDXParser()
    private let mddParser = MDDParser()
    private let plainTextNormalizer = HTMLPlainTextNormalizer()

    private init() {}

    func importDictionary(
        dictionaryID: String,
        preferredDisplayName: String,
        sourceFolderURL: URL,
        sourceFolderIsInternal: Bool
    ) throws -> DictionaryIndexResult {
        let dictionaryRoot = try UserStoragePaths.dictionaryFolderURL(id: dictionaryID, createIfNeeded: true)
        let internalSourceFolder = dictionaryRoot.appendingPathComponent("source", isDirectory: true)
        let indexFolder = dictionaryRoot.appendingPathComponent("index", isDirectory: true)

        try ensureDirectory(indexFolder)

        let packageLayout: DictionaryPackageLayout
        let effectiveSourceFolder: URL

        if sourceFolderIsInternal {
            try ensureReadableDirectory(sourceFolderURL)
            try ensureNoSymbolicLinks(in: sourceFolderURL)
            packageLayout = try scanPackageLayout(in: sourceFolderURL)
            effectiveSourceFolder = sourceFolderURL
        } else {
            let didAccess = sourceFolderURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceFolderURL.stopAccessingSecurityScopedResource()
                }
            }

            try ensureReadableDirectory(sourceFolderURL)
            try ensureNoSymbolicLinks(in: sourceFolderURL)
            let scanned = try scanPackageLayout(in: sourceFolderURL)
            try copyDirectoryTree(from: sourceFolderURL, to: internalSourceFolder)
            try ensureNoSymbolicLinks(in: internalSourceFolder)
            packageLayout = scanned.rebased(to: internalSourceFolder)
            effectiveSourceFolder = internalSourceFolder
        }

        let dbURL = indexFolder.appendingPathComponent("dictionary.sqlite", isDirectory: false)
        let buildSummary = try buildIndexDatabase(
            at: dbURL,
            mdxURL: packageLayout.mdxURL,
            mddURLs: packageLayout.mddURLs
        )

        let fallbackName = packageLayout.mdxURL.deletingPathExtension().lastPathComponent
        let titleFromHeader = buildSummary.header["Title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName: String
        if !preferredDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedDisplayName = preferredDisplayName
        } else if let titleFromHeader, !titleFromHeader.isEmpty {
            resolvedDisplayName = titleFromHeader
        } else {
            resolvedDisplayName = fallbackName
        }

        return DictionaryIndexResult(
            dictionaryID: dictionaryID,
            displayName: resolvedDisplayName,
            dbURL: dbURL,
            sourceFolderURL: effectiveSourceFolder,
            mdxRelativePath: packageLayout.mdxRelativePath,
            mddRelativePath: packageLayout.mddRelativePath,
            mddImportStats: buildSummary.mddImportStats,
            entryCount: buildSummary.entryCount,
            profile: buildSummary.profile
        )
    }

    private func scanPackageLayout(in sourceFolderURL: URL) throws -> DictionaryPackageLayout {
        struct Candidate {
            let relativePath: String
            let url: URL
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourceFolderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DictionaryImportError.unreadableDirectory
        }

        var mdxCandidates: [Candidate] = []
        var mddCandidates: [Candidate] = []

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard let relativePath = relativePath(of: fileURL, from: sourceFolderURL) else { continue }

            switch fileURL.pathExtension.lowercased() {
            case "mdx":
                mdxCandidates.append(Candidate(relativePath: relativePath, url: fileURL))
            case "mdd":
                mddCandidates.append(Candidate(relativePath: relativePath, url: fileURL))
            default:
                continue
            }
        }

        guard !mdxCandidates.isEmpty else {
            throw DictionaryImportError.noMDX
        }
        guard mdxCandidates.count == 1 else {
            throw DictionaryImportError.multipleMDX
        }

        let mdx = mdxCandidates[0]
        let mdxBaseName = baseName(of: mdx.relativePath)

        let selectedMDDs: [Candidate]
        switch mddCandidates.count {
        case 0:
            selectedMDDs = []
        case 1:
            selectedMDDs = mddCandidates
        default:
            let matched = mddCandidates.filter {
                isMatchingMDDBaseName(
                    baseName(of: $0.relativePath),
                    mdxBaseName: mdxBaseName
                )
            }

            guard !matched.isEmpty else {
                throw DictionaryImportError.ambiguousMDD
            }

            selectedMDDs = matched.sorted { lhs, rhs in
                let lhsBase = baseName(of: lhs.relativePath)
                let rhsBase = baseName(of: rhs.relativePath)
                let lhsPrimary = lhsBase.caseInsensitiveCompare(mdxBaseName) == .orderedSame
                let rhsPrimary = rhsBase.caseInsensitiveCompare(mdxBaseName) == .orderedSame

                if lhsPrimary != rhsPrimary {
                    return lhsPrimary && !rhsPrimary
                }

                return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            }
        }

        return DictionaryPackageLayout(
            mdxRelativePath: mdx.relativePath,
            mddRelativePaths: selectedMDDs.map(\.relativePath),
            mdxURL: mdx.url,
            mddURLs: selectedMDDs.map(\.url)
        )
    }

    private func baseName(of relativePath: String) -> String {
        URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
    }

    private func isMatchingMDDBaseName(_ candidateBaseName: String, mdxBaseName: String) -> Bool {
        if candidateBaseName.caseInsensitiveCompare(mdxBaseName) == .orderedSame {
            return true
        }

        let prefix = mdxBaseName + "."
        return candidateBaseName.lowercased().hasPrefix(prefix.lowercased())
    }

    private func importMDDAssets(from mddURLs: [URL], into queue: DatabaseQueue) throws -> MDDImportStats {
        guard !mddURLs.isEmpty else { return .empty }

        var acceptedTotalBytes: Int64 = 0
        let fm = FileManager.default
        var importedFileCount = 0
        var skippedReasons: [String] = []

        for mddURL in mddURLs {
            let fileSize = fileSizeInBytes(of: mddURL, fm: fm) ?? 0
            if let skipReason = shouldSkipMDD(
                fileURL: mddURL,
                fileSize: fileSize,
                acceptedTotalBytes: acceptedTotalBytes
            ) {
                print("Warning:", skipReason)
                appendSkipReason(skipReason, into: &skippedReasons)
                continue
            }

            do {
                var batch: [MDDAssetRecord] = []
                batch.reserveCapacity(DictionaryImportTuning.mddAssetBatchSize)

                try mddParser.enumerateAssets(fileURL: mddURL) { asset in
                    batch.append(asset)
                    if batch.count >= DictionaryImportTuning.mddAssetBatchSize {
                        try self.flushMDDAssetBatch(batch, into: queue)
                        batch.removeAll(keepingCapacity: true)
                    }
                }

                if !batch.isEmpty {
                    try flushMDDAssetBatch(batch, into: queue)
                }

                acceptedTotalBytes += fileSize
                importedFileCount += 1
            } catch {
                let reason = "跳过 \(mddURL.lastPathComponent)：\(error.localizedDescription)"
                print("Warning:", reason)
                appendSkipReason(reason, into: &skippedReasons)
            }
        }

        let assetCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mdd_asset_index") ?? 0
        }

        return MDDImportStats(
            scannedFileCount: mddURLs.count,
            importedFileCount: importedFileCount,
            assetCount: assetCount,
            skippedReasons: skippedReasons
        )
    }

    private func flushMDDAssetBatch(
        _ batch: [MDDAssetRecord],
        into queue: DatabaseQueue
    ) throws {
        guard !batch.isEmpty else { return }

        try queue.write { db in
            for asset in batch {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO mdd_asset_index(path_norm, original_key, data, mime)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [asset.pathNorm, asset.originalKey, asset.data, asset.mimeType]
                )
            }
        }
    }

    private func shouldSkipMDD(
        fileURL: URL,
        fileSize: Int64,
        acceptedTotalBytes: Int64
    ) -> String? {
        if fileSize > DictionaryImportTuning.maxSingleMDDBytes {
            return "跳过 \(fileURL.lastPathComponent)：文件大小 \(fileSize) 超过单文件限制 \(DictionaryImportTuning.maxSingleMDDBytes)"
        }

        if acceptedTotalBytes + fileSize > DictionaryImportTuning.maxTotalMDDBytes {
            return "跳过 \(fileURL.lastPathComponent)：累计大小超过总预算 \(DictionaryImportTuning.maxTotalMDDBytes)"
        }

        return nil
    }

    private func appendSkipReason(_ reason: String, into reasons: inout [String]) {
        guard reasons.count < DictionaryImportTuning.maxReportedSkipReasons else { return }
        reasons.append(reason)
    }

    private func fileSizeInBytes(of url: URL, fm: FileManager) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return nil
        }
        return Int64(fileSize)
    }

    private func relativePath(of fileURL: URL, from rootURL: URL) -> String? {
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"

        guard resolvedFile.hasPrefix(prefix) else { return nil }
        let relative = String(resolvedFile.dropFirst(prefix.count))
        return relative.replacingOccurrences(of: "\\", with: "/")
    }

    private func copyDirectoryTree(from sourceFolderURL: URL, to destinationFolderURL: URL) throws {
        let fm = FileManager.default
        try ensureDirectory(destinationFolderURL.deletingLastPathComponent())

        if fm.fileExists(atPath: destinationFolderURL.path) {
            try fm.removeItem(at: destinationFolderURL)
        }

        try fm.copyItem(at: sourceFolderURL, to: destinationFolderURL)
    }

    private func ensureReadableDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw DictionaryImportError.unreadableDirectory
        }

        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DictionaryImportError.unreadableDirectory
        }
    }

    private func ensureNoSymbolicLinks(in rootURL: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DictionaryImportError.unreadableDirectory
        }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let displayPath = displayRelativePath(of: fileURL, from: rootURL)
                throw DictionaryImportError.containsSymbolicLink(displayPath)
            }
        }
    }

    private func displayRelativePath(of fileURL: URL, from rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard filePath.hasPrefix(prefix) else {
            return fileURL.lastPathComponent
        }
        return String(filePath.dropFirst(prefix.count))
    }

    private func buildIndexDatabase(
        at dbURL: URL,
        mdxURL: URL,
        mddURLs: [URL]
    ) throws -> IndexBuildSummary {
        let fm = FileManager.default
        let shmURL = dbURL.appendingPathExtension("shm")
        let walURL = dbURL.appendingPathExtension("wal")

        if fm.fileExists(atPath: dbURL.path) {
            try fm.removeItem(at: dbURL)
        }
        if fm.fileExists(atPath: shmURL.path) {
            try fm.removeItem(at: shmURL)
        }
        if fm.fileExists(atPath: walURL.path) {
            try fm.removeItem(at: walURL)
        }

        let queue = try DatabaseQueue(path: dbURL.path)

        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
        }

        try createIndexSchema(in: queue)

        var profile = DictionaryNormalizationProfile(stripKey: false, keyCaseSensitive: false)
        var header: [String: String] = [:]
        var hasMetadata = false

        var batch: [MDXEntryRecord] = []
        batch.reserveCapacity(DictionaryImportTuning.entryBatchSize)

        let summary = try mdxParser.streamEntries(
            fileURL: mdxURL,
            onMetadata: { attributes, normalization in
                header = attributes
                profile = normalization
                hasMetadata = true
            },
            onEntry: { [self] entry in
                guard hasMetadata else {
                    throw MDictParserError.invalidFormat("MDX header metadata missing before entries")
                }

                batch.append(entry)
                if batch.count >= DictionaryImportTuning.entryBatchSize {
                    try self.flushEntryBatch(batch, profile: profile, into: queue)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        )

        if !batch.isEmpty {
            try flushEntryBatch(batch, profile: profile, into: queue)
        }

        if !hasMetadata {
            profile = summary.normalizationProfile
            header = summary.header
        }

        try upsertDictionaryMeta(profile: profile, in: queue)
        try rebuildFTSAndInstallTriggers(in: queue)
        let mddImportStats = try importMDDAssets(from: mddURLs, into: queue)

        return IndexBuildSummary(
            entryCount: summary.entryCount,
            profile: profile,
            header: header,
            mddImportStats: mddImportStats
        )
    }

    private func createIndexSchema(in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE entries (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
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

            try db.execute(sql: """
            CREATE TABLE entry_html (
              entry_id INTEGER PRIMARY KEY,
              entry_key TEXT NOT NULL,
              html TEXT NOT NULL,
              FOREIGN KEY(entry_id) REFERENCES entries(id) ON DELETE CASCADE
            );
            """)

            try db.execute(sql: """
            CREATE TABLE dictionary_meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)

            try db.execute(sql: """
            CREATE TABLE lemma_map (
              form TEXT PRIMARY KEY,
              lemma TEXT NOT NULL
            ) WITHOUT ROWID;
            """)

            try db.execute(sql: """
            CREATE TABLE mdd_asset_index (
              path_norm TEXT PRIMARY KEY,
              original_key TEXT NOT NULL,
              data BLOB NOT NULL,
              mime TEXT NOT NULL
            );
            """)

            try db.execute(sql: """
            CREATE INDEX idx_entries_word_nocase
            ON entries(word COLLATE NOCASE);
            """)
            try db.execute(sql: """
            CREATE INDEX idx_entries_lemma_nocase
            ON entries(lemma COLLATE NOCASE);
            """)
            try db.execute(sql: """
            CREATE INDEX idx_entries_frequency
            ON entries(frequency);
            """)
            try db.execute(sql: """
            CREATE INDEX idx_entry_html_key_nocase
            ON entry_html(entry_key COLLATE NOCASE);
            """)
            try db.execute(sql: """
            CREATE INDEX idx_mdd_asset_original_nocase
            ON mdd_asset_index(original_key COLLATE NOCASE);
            """)

            try db.execute(sql: """
            CREATE VIRTUAL TABLE entries_fts
            USING fts5(
              word,
              lemma,
              hwd,
              definition,
              content='entries',
              content_rowid='id'
            );
            """)
        }
    }

    private func flushEntryBatch(
        _ entries: [MDXEntryRecord],
        profile: DictionaryNormalizationProfile,
        into queue: DatabaseQueue
    ) throws {
        guard !entries.isEmpty else { return }

        try queue.write { db in
            for entry in entries {
                try autoreleasepool {
                    let lemma = entry.key
                    let definition = plainTextNormalizer.normalize(entry.html)

                    try db.execute(
                        sql: """
                        INSERT INTO entries(word, lemma, pos, phonetic, frequency, level, definition, examples, idioms, origination, hwd)
                        VALUES (?, ?, '', '', 0, '', ?, '', '', '', '')
                        """,
                        arguments: [entry.key, lemma, definition]
                    )

                    let entryID = db.lastInsertedRowID

                    try db.execute(
                        sql: "INSERT INTO entry_html(entry_id, entry_key, html) VALUES (?, ?, ?)",
                        arguments: [entryID, entry.key, entry.html]
                    )

                    let normalizedForm = profile.normalizeForLookup(entry.key)
                    if !normalizedForm.isEmpty {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO lemma_map(form, lemma) VALUES (?, ?)",
                            arguments: [normalizedForm, lemma]
                        )
                    }
                }
            }
        }
    }

    private func upsertDictionaryMeta(
        profile: DictionaryNormalizationProfile,
        in queue: DatabaseQueue
    ) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM dictionary_meta;")
            try db.execute(
                sql: "INSERT INTO dictionary_meta(key, value) VALUES (?, ?)",
                arguments: ["strip_key", profile.stripKey ? "1" : "0"]
            )
            try db.execute(
                sql: "INSERT INTO dictionary_meta(key, value) VALUES (?, ?)",
                arguments: ["key_case_sensitive", profile.keyCaseSensitive ? "1" : "0"]
            )
        }
    }

    private func rebuildFTSAndInstallTriggers(in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO entries_fts(entries_fts) VALUES ('rebuild');")
        }

        try queue.write { db in
            try db.execute(sql: """
            CREATE TRIGGER trg_entries_ai
            AFTER INSERT ON entries
            BEGIN
              INSERT INTO entries_fts(rowid, word, lemma, hwd, definition)
              VALUES (new.id, new.word, new.lemma, new.hwd, new.definition);
            END;
            """)

            try db.execute(sql: """
            CREATE TRIGGER trg_entries_ad
            AFTER DELETE ON entries
            BEGIN
              INSERT INTO entries_fts(entries_fts, rowid, word, lemma, hwd, definition)
              VALUES ('delete', old.id, old.word, old.lemma, old.hwd, old.definition);
            END;
            """)

            try db.execute(sql: """
            CREATE TRIGGER trg_entries_au
            AFTER UPDATE ON entries
            BEGIN
              INSERT INTO entries_fts(entries_fts, rowid, word, lemma, hwd, definition)
              VALUES ('delete', old.id, old.word, old.lemma, old.hwd, old.definition);

              INSERT INTO entries_fts(rowid, word, lemma, hwd, definition)
              VALUES (new.id, new.word, new.lemma, new.hwd, new.definition);
            END;
            """)
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if exists {
            guard isDirectory.boolValue else {
                throw NSError(
                    domain: "DictionaryImportIndexer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "目标路径不是目录：\(url.path)"]
                )
            }
            return
        }

        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
