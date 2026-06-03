//
//  AppState.swift
//  FuckYouXcode
//
//  Created by 马逸凡 on 2026/2/11.
//
import Combine
import Foundation
import GRDB

struct DictionaryOption: Identifiable, Hashable {
    enum SourceKind: String {
        case builtin
        case imported
    }

    enum Status: String {
        case ready
        case indexing
        case failed

        var isSelectable: Bool {
            self == .ready
        }

        var localizedSuffix: String? {
            switch self {
            case .ready:
                return nil
            case .indexing:
                return "（索引中）"
            case .failed:
                return "（失败）"
            }
        }
    }

    static let defaultID = "builtin.default"

    let id: String
    let displayName: String
    let isBuiltin: Bool
    let sourceKind: SourceKind
    let status: Status
    let sourceRecordID: String?
    let mdxFileName: String?

    static let `default` = DictionaryOption(
        id: DictionaryOption.defaultID,
        displayName: "默认词典",
        isBuiltin: true,
        sourceKind: .builtin,
        status: .ready,
        sourceRecordID: nil,
        mdxFileName: nil
    )

    var localizedDisplayName: String {
        guard let suffix = status.localizedSuffix else {
            return displayName
        }
        return "\(displayName)\(suffix)"
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var dictionaryService: DictionaryService?
    @Published private(set) var dictionaryServicesByID: [String: DictionaryService] = [:]
    @Published var dictionaryOptions: [DictionaryOption] = [.default]
    @Published var selectedDictionaryID: String = DictionaryOption.defaultID
    @Published private(set) var isBootstrapping = false
    @Published private(set) var bootstrapErrorMessage: String?

    private let catalogStore: DictionaryCatalogStore
    private let importIndexer: DictionaryImportIndexer

    private var builtinDictionaryService: DictionaryService?
    private var inFlightDictionaryIDs: Set<String> = []

    private static let staleIndexingMessage = "上次导入被系统中断，请重试。"

    init(
        catalogStore: DictionaryCatalogStore,
        importIndexer: DictionaryImportIndexer
    ) {
        self.catalogStore = catalogStore
        self.importIndexer = importIndexer
    }

    convenience init() {
        self.init(catalogStore: .shared, importIndexer: .shared)
    }

    func bootstrap() async {
        isBootstrapping = true
        bootstrapErrorMessage = nil
        defer { isBootstrapping = false }

        do {
            try await UserDB.shared.prepareIfNeeded()
            try DictionaryDB.shared.prepareIfNeeded_()
            guard let queue = DictionaryDB.shared.dbQueue else {
                throw NSError(
                    domain: "AppState",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "默认词典数据库未初始化"]
                )
            }

            let service = try DictionaryService(dbQueue: queue)
            builtinDictionaryService = service

            _ = try catalogStore.markStaleIndexingRecordsAsFailed(
                activeIDs: inFlightDictionaryIDs,
                message: Self.staleIndexingMessage
            )
            try removeFailedRecordsAndArtifacts()
            let records = try catalogStore.loadRecords()
            try applyCatalog(records: records, preferredSelectionID: DictionaryOption.defaultID)
        } catch {
            print("❌ bootstrap failed:", error)
            dictionaryServicesByID = [:]
            dictionaryOptions = [.default]
            selectedDictionaryID = DictionaryOption.defaultID
            dictionaryService = nil
            bootstrapErrorMessage = error.localizedDescription
        }
    }

    func retryBootstrap() async {
        await bootstrap()
    }

    func service(for dictionaryID: String) -> DictionaryService? {
        dictionaryServicesByID[dictionaryID] ?? dictionaryServicesByID[DictionaryOption.defaultID]
    }

    func option(for dictionaryID: String) -> DictionaryOption? {
        dictionaryOptions.first(where: { $0.id == dictionaryID })
    }

    func sourceFolderURL(for dictionaryID: String) -> URL? {
        guard dictionaryID != DictionaryOption.defaultID else { return nil }
        guard let record = try? catalogStore.record(id: dictionaryID),
              !record.sourceFolderPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: record.sourceFolderPath, isDirectory: true)
    }

    func selectDictionary(id: String) {
        guard let option = dictionaryOptions.first(where: { $0.id == id }), option.status.isSelectable else {
            return
        }

        selectedDictionaryID = option.id
        dictionaryService = service(for: option.id)
    }

    func importDictionary(folderURL: URL) async {
        let baseNameRaw = folderURL.deletingPathExtension().lastPathComponent
        let baseName = baseNameRaw.isEmpty ? "Imported Dictionary" : baseNameRaw
        let dictionaryID = makeImportedDictionaryID(from: baseName)

        let rootURL: URL
        do {
            rootURL = try UserStoragePaths.dictionaryFolderURL(id: dictionaryID, createIfNeeded: true)
        } catch {
            print("❌ failed to prepare dictionary folder:", error)
            return
        }

        let placeholder = DictionaryCatalogRecord(
            id: dictionaryID,
            displayName: baseName,
            status: .indexing,
            mdxFileName: "",
            mddFileName: nil,
            hasMDD: false,
            dbPath: rootURL.appendingPathComponent("index/dictionary.sqlite", isDirectory: false).path,
            sourceFolderPath: rootURL.appendingPathComponent("source", isDirectory: true).path,
            lastError: nil
        )

        do {
            _ = try catalogStore.upsert(record: placeholder)
            try await refreshCatalog(preferredSelectionID: selectedDictionaryID)

            inFlightDictionaryIDs.insert(dictionaryID)
            defer { inFlightDictionaryIDs.remove(dictionaryID) }

            let result = try await runImportWork {
                try self.importIndexer.importDictionary(
                    dictionaryID: dictionaryID,
                    preferredDisplayName: baseName,
                    sourceFolderURL: folderURL,
                    sourceFolderIsInternal: false
                )
            }

            var success = placeholder
            success.displayName = result.displayName
            success.status = .ready
            success.mdxFileName = result.mdxRelativePath
            success.mddFileName = result.mddRelativePath
            success.hasMDD = result.mddImportStats.hasAssets
            success.dbPath = result.dbURL.path
            success.sourceFolderPath = result.sourceFolderURL.path
            success.lastError = result.mddImportStats.warningMessage
            success.updatedAt = Date().timeIntervalSince1970

            if let warning = result.mddImportStats.warningMessage {
                print("⚠️ importDictionary warning:", warning)
            }

            _ = try catalogStore.upsert(record: success)
            do {
                try removeFailedRecordsAndArtifacts()
            } catch {
                print("⚠️ failed to clean failed dictionary placeholders:", error.localizedDescription)
            }
            try await refreshCatalog(preferredSelectionID: success.id)
        } catch {
            print("❌ importDictionary failed:", error.localizedDescription)
            do {
                _ = try catalogStore.updateRecord(id: dictionaryID) { record in
                    record.status = .failed
                    record.lastError = error.localizedDescription
                }
                try removeFailedRecordsAndArtifacts()
                try await refreshCatalog(preferredSelectionID: selectedDictionaryID)
            } catch {
                print("❌ failed to persist import error:", error)
            }
        }
    }

    func rebuildIndex(for dictionaryID: String) async {
        do {
            guard var record = try catalogStore.record(id: dictionaryID) else {
                return
            }

            record.status = .indexing
            record.lastError = nil
            record.updatedAt = Date().timeIntervalSince1970
            _ = try catalogStore.upsert(record: record)

            dictionaryServicesByID[dictionaryID] = nil
            if selectedDictionaryID == dictionaryID {
                selectedDictionaryID = DictionaryOption.defaultID
            }

            try await refreshCatalog(preferredSelectionID: selectedDictionaryID)

            let sourceFolder = URL(fileURLWithPath: record.sourceFolderPath, isDirectory: true)

            inFlightDictionaryIDs.insert(dictionaryID)
            defer { inFlightDictionaryIDs.remove(dictionaryID) }

            let result = try await runImportWork {
                try self.importIndexer.importDictionary(
                    dictionaryID: dictionaryID,
                    preferredDisplayName: record.displayName,
                    sourceFolderURL: sourceFolder,
                    sourceFolderIsInternal: true
                )
            }

            record.displayName = result.displayName
            record.status = .ready
            record.mdxFileName = result.mdxRelativePath
            record.mddFileName = result.mddRelativePath
            record.hasMDD = result.mddImportStats.hasAssets
            record.dbPath = result.dbURL.path
            record.sourceFolderPath = result.sourceFolderURL.path
            record.updatedAt = Date().timeIntervalSince1970
            record.lastError = result.mddImportStats.warningMessage

            if let warning = result.mddImportStats.warningMessage {
                print("⚠️ rebuildIndex warning:", warning)
            }

            _ = try catalogStore.upsert(record: record)
            try await refreshCatalog(preferredSelectionID: dictionaryID)
        } catch {
            print("❌ rebuildIndex failed:", error.localizedDescription)
            do {
                _ = try catalogStore.updateRecord(id: dictionaryID) { record in
                    record.status = .failed
                    record.lastError = error.localizedDescription
                }
                try await refreshCatalog(preferredSelectionID: selectedDictionaryID)
            } catch {
                print("❌ rebuild failure persistence failed:", error)
            }
        }
    }

#if DEBUG
    func importOxfordDictionaryForTestingIfNeeded() async {
        let folderName = "牛津词典"
        guard dictionaryOptions.contains(where: { $0.displayName == folderName }) == false else {
            return
        }

        guard let folderURL = resolveTestingDictionaryFolder(named: folderName) else {
            print("⚠️ testing dictionary folder not found:", folderName)
            return
        }

        await importDictionary(folderURL: folderURL)
    }
#endif

    private func runImportWork<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func refreshCatalog(preferredSelectionID: String?) async throws {
        let records = try catalogStore.loadRecords()
        try applyCatalog(records: records, preferredSelectionID: preferredSelectionID)
    }

    private func removeFailedRecordsAndArtifacts(excludingIDs: Set<String> = []) throws {
        let records = try catalogStore.loadRecords()
        let failedIDs = records
            .filter { record in
                record.status == .failed && !excludingIDs.contains(record.id)
            }
            .map(\.id)
        let activeRecordIDs = Set(records.map(\.id))
        let orphanedFolderIDs = try orphanedDictionaryFolderIDs(activeRecordIDs: activeRecordIDs)

        guard !failedIDs.isEmpty || !orphanedFolderIDs.isEmpty else { return }

        if !failedIDs.isEmpty {
            _ = try catalogStore.removeFailedRecords(excludingIDs: excludingIDs)
        }

        let fm = FileManager.default
        for dictionaryID in Set(failedIDs).union(orphanedFolderIDs) {
            do {
                let dictionaryFolder = try UserStoragePaths.dictionaryFolderURL(
                    id: dictionaryID,
                    createIfNeeded: false
                )
                guard fm.fileExists(atPath: dictionaryFolder.path) else { continue }
                try fm.removeItem(at: dictionaryFolder)
            } catch {
                print("⚠️ failed to remove failed dictionary folder \(dictionaryID):", error.localizedDescription)
            }
        }
    }

    private func orphanedDictionaryFolderIDs(activeRecordIDs: Set<String>) throws -> Set<String> {
        let fm = FileManager.default
        let dictionariesRoot = try UserStoragePaths.dictionariesRootURL(createIfNeeded: true)
        let contents = try fm.contentsOfDirectory(
            at: dictionariesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try Set(contents.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }

            let folderID = url.lastPathComponent
            guard folderID.hasPrefix("imported.") else { return nil }
            guard !activeRecordIDs.contains(folderID) else { return nil }
            return folderID
        })
    }

    private func applyCatalog(records: [DictionaryCatalogRecord], preferredSelectionID: String?) throws {
        guard let builtinDictionaryService else {
            throw NSError(
                domain: "AppState",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "默认词典尚未初始化"]
            )
        }

        var servicesByID: [String: DictionaryService] = [DictionaryOption.defaultID: builtinDictionaryService]
        var options: [DictionaryOption] = [.default]

        var updatedRecords = records
        var hasRecordUpdates = false

        for idx in updatedRecords.indices {
            var record = updatedRecords[idx]
            var status = optionStatus(from: record.status)

            if record.status == .ready {
                do {
                    let service = try makeService(dbPath: record.dbPath)
                    servicesByID[record.id] = service
                } catch {
                    status = .failed
                    record.status = .failed
                    record.lastError = error.localizedDescription
                    record.updatedAt = Date().timeIntervalSince1970
                    updatedRecords[idx] = record
                    hasRecordUpdates = true
                }
            }

            options.append(
                DictionaryOption(
                    id: record.id,
                    displayName: record.displayName,
                    isBuiltin: false,
                    sourceKind: .imported,
                    status: status,
                    sourceRecordID: record.id,
                    mdxFileName: record.mdxFileName
                )
            )
        }

        if hasRecordUpdates {
            try catalogStore.saveRecords(updatedRecords)
        }

        options = [DictionaryOption.default] + options
            .dropFirst()
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        dictionaryServicesByID = servicesByID
        dictionaryOptions = options

        let preferred = preferredSelectionID ?? selectedDictionaryID
        if let selected = options.first(where: { $0.id == preferred && $0.status.isSelectable }) {
            selectedDictionaryID = selected.id
        } else {
            selectedDictionaryID = DictionaryOption.defaultID
        }

        dictionaryService = service(for: selectedDictionaryID)
    }

    private func makeService(dbPath: String) throws -> DictionaryService {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw NSError(
                domain: "AppState",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "词典索引数据库不存在：\(dbPath)"]
            )
        }

        var config = Configuration()
        config.readonly = false
        let queue = try DatabaseQueue(path: dbPath, configuration: config)
        return try DictionaryService(dbQueue: queue)
    }

    private func optionStatus(from status: DictionaryCatalogStatus) -> DictionaryOption.Status {
        switch status {
        case .ready:
            return .ready
        case .indexing:
            return .indexing
        case .failed:
            return .failed
        }
    }

    private func makeImportedDictionaryID(from baseName: String) -> String {
        let safeName = baseName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression)
        let suffix = UUID().uuidString.prefix(8)
        return "imported.\(safeName.lowercased()).\(suffix)"
    }

#if DEBUG
    private func resolveTestingDictionaryFolder(named folderName: String) -> URL? {
        let fm = FileManager.default
        let sourceRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["MDX_TEST_DICTIONARY_FOLDER"],
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: explicit, isDirectory: true))
        }
        if let resourceRoot = Bundle.main.resourceURL {
            candidates.append(resourceRoot.appendingPathComponent(folderName, isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(folderName, isDirectory: true))
        candidates.append(cwd.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true))
        candidates.append(sourceRoot.appendingPathComponent(folderName, isDirectory: true))

        var seen: Set<String> = []
        for candidate in candidates {
            let normalizedPath = candidate.standardizedFileURL.path
            guard seen.insert(normalizedPath).inserted else { continue }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: normalizedPath, isDirectory: true)
            }
        }

        return nil
    }
#endif
}
