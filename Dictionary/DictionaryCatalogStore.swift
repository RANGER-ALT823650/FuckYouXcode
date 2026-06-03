import Foundation

enum DictionaryCatalogSourceKind: String, Codable {
    case imported
}

enum DictionaryCatalogStatus: String, Codable {
    case ready
    case indexing
    case failed
}

struct DictionaryCatalogRecord: Codable, Identifiable, Hashable {
    let id: String
    var displayName: String
    var sourceKind: DictionaryCatalogSourceKind
    var status: DictionaryCatalogStatus
    var mdxFileName: String
    var mddFileName: String?
    var hasMDD: Bool
    var dbPath: String
    var sourceFolderPath: String
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var lastError: String?

    init(
        id: String,
        displayName: String,
        sourceKind: DictionaryCatalogSourceKind = .imported,
        status: DictionaryCatalogStatus,
        mdxFileName: String,
        mddFileName: String? = nil,
        hasMDD: Bool,
        dbPath: String,
        sourceFolderPath: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        lastError: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.status = status
        self.mdxFileName = mdxFileName
        self.mddFileName = mddFileName
        self.hasMDD = hasMDD
        self.dbPath = dbPath
        self.sourceFolderPath = sourceFolderPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastError = lastError
    }
}

final class DictionaryCatalogStore {
    static let shared = DictionaryCatalogStore()

    private let fileURL: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func loadRecords() throws -> [DictionaryCatalogRecord] {
        let fileURL = try resolvedFileURL()
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try Data("[]".utf8).write(to: fileURL, options: .atomic)
            return []
        }

        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return []
        }

        do {
            return try decoder.decode([DictionaryCatalogRecord].self, from: data)
        } catch {
            throw NSError(
                domain: "DictionaryCatalogStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "词典目录文件解析失败：\(error.localizedDescription)"]
            )
        }
    }

    func saveRecords(_ records: [DictionaryCatalogRecord]) throws {
        let fileURL = try resolvedFileURL()
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    private func resolvedFileURL() throws -> URL {
        if let fileURL {
            return fileURL
        }
        return try UserStoragePaths.dictionaryCatalogURL(createIfNeeded: true)
    }

    @discardableResult
    func upsert(record: DictionaryCatalogRecord) throws -> [DictionaryCatalogRecord] {
        var records = try loadRecords()
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        records.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.createdAt < rhs.createdAt
        }
        try saveRecords(records)
        return records
    }

    @discardableResult
    func removeRecord(id: String) throws -> [DictionaryCatalogRecord] {
        var records = try loadRecords()
        records.removeAll { $0.id == id }
        try saveRecords(records)
        return records
    }

    @discardableResult
    func removeFailedRecords(excludingIDs: Set<String> = []) throws -> [DictionaryCatalogRecord] {
        let records = try loadRecords()
        let filtered = records.filter { record in
            if record.status != .failed { return true }
            return excludingIDs.contains(record.id)
        }

        if filtered.count != records.count {
            try saveRecords(filtered)
        }

        return filtered
    }

    func record(id: String) throws -> DictionaryCatalogRecord? {
        try loadRecords().first(where: { $0.id == id })
    }

    @discardableResult
    func updateRecord(
        id: String,
        _ update: (inout DictionaryCatalogRecord) -> Void
    ) throws -> [DictionaryCatalogRecord] {
        var records = try loadRecords()
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            return records
        }

        update(&records[idx])
        records[idx].updatedAt = Date().timeIntervalSince1970

        try saveRecords(records)
        return records
    }

    @discardableResult
    func markStaleIndexingRecordsAsFailed(
        activeIDs: Set<String>,
        message: String
    ) throws -> [DictionaryCatalogRecord] {
        var records = try loadRecords()
        var changed = false
        let now = Date().timeIntervalSince1970

        for idx in records.indices {
            guard records[idx].status == .indexing else {
                continue
            }
            guard !activeIDs.contains(records[idx].id) else {
                continue
            }

            records[idx].status = .failed
            records[idx].lastError = message
            records[idx].updatedAt = now
            changed = true
        }

        if changed {
            try saveRecords(records)
        }

        return records
    }
}
