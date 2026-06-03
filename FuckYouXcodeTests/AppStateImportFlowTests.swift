import Compression
import Foundation
import Testing
@testable import FuckYouXcode

@Suite(.serialized)
struct AppStateImportFlowTests {
    @Test
    @MainActor
    func successfulImportRemovesFailedCatalogPlaceholders() async throws {
        let (catalogStore, catalogRoot) = try makeCatalogStore()
        defer { try? FileManager.default.removeItem(at: catalogRoot) }

        let packageRoot = try makeTempDirectory(prefix: "appstate_import_flow")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let failedRecord = DictionaryCatalogRecord(
            id: "imported.failed.placeholder",
            displayName: "Broken Dictionary",
            status: .failed,
            mdxFileName: "broken.mdx",
            hasMDD: false,
            dbPath: "/tmp/broken.sqlite",
            sourceFolderPath: "/tmp/broken"
        )
        _ = try catalogStore.upsert(record: failedRecord)

        let mdxURL = packageRoot
            .appendingPathComponent("dict", isDirectory: true)
            .appendingPathComponent("main.mdx", isDirectory: false)
        try FileManager.default.createDirectory(
            at: mdxURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeMinimalMDX(at: mdxURL, entryKey: "hello", html: "<div>Hello</div>")

        let appState = AppState(catalogStore: catalogStore, importIndexer: .shared)
        await appState.bootstrap()
        await appState.importDictionary(folderURL: packageRoot)

        let records = try catalogStore.loadRecords()
        #expect(records.contains(where: { $0.status == .failed }) == false)
        #expect(records.contains(where: { $0.status == .ready }))

        for record in records {
            if let dictionaryFolder = try? UserStoragePaths.dictionaryFolderURL(id: record.id, createIfNeeded: false) {
                try? FileManager.default.removeItem(at: dictionaryFolder)
            }
        }
    }

    @Test
    @MainActor
    func failedImportRemovesCopiedDictionaryFolder() async throws {
        let (catalogStore, catalogRoot) = try makeCatalogStore()
        defer { try? FileManager.default.removeItem(at: catalogRoot) }

        let packageRoot = try makeTempDirectory(prefix: "appstate_failed_cleanup")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let brokenMDXURL = packageRoot
            .appendingPathComponent("dict", isDirectory: true)
            .appendingPathComponent("broken.mdx", isDirectory: false)
        try FileManager.default.createDirectory(
            at: brokenMDXURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a valid mdx payload".utf8).write(to: brokenMDXURL, options: .atomic)

        let folderPrefix = importedFolderPrefix(for: packageRoot.lastPathComponent)
        let dictionariesRoot = try UserStoragePaths.dictionariesRootURL(createIfNeeded: true)

        let appState = AppState(catalogStore: catalogStore, importIndexer: .shared)
        await appState.bootstrap()
        await appState.importDictionary(folderURL: packageRoot)

        let remainingFolders = try importedDictionaryFolders(
            in: dictionariesRoot,
            matchingPrefix: folderPrefix
        )
        #expect(remainingFolders.isEmpty)

        let records = try catalogStore.loadRecords()
        #expect(records.contains(where: { $0.id.hasPrefix(folderPrefix) }) == false)
    }

    @Test
    @MainActor
    func bootstrapRemovesFailedAndOrphanedDictionaryFolders() async throws {
        let (catalogStore, catalogRoot) = try makeCatalogStore()
        defer { try? FileManager.default.removeItem(at: catalogRoot) }

        let failedID = "imported.bootstrap.failed.\(UUID().uuidString.lowercased())"
        let orphanID = "imported.bootstrap.orphan.\(UUID().uuidString.lowercased())"

        let failedFolder = try UserStoragePaths.dictionaryFolderURL(id: failedID, createIfNeeded: true)
        let orphanFolder = try UserStoragePaths.dictionaryFolderURL(id: orphanID, createIfNeeded: true)
        defer {
            try? FileManager.default.removeItem(at: failedFolder)
            try? FileManager.default.removeItem(at: orphanFolder)
        }

        try Data("failed".utf8).write(
            to: failedFolder.appendingPathComponent("payload.bin", isDirectory: false),
            options: .atomic
        )
        try Data("orphan".utf8).write(
            to: orphanFolder.appendingPathComponent("payload.bin", isDirectory: false),
            options: .atomic
        )

        let failedRecord = DictionaryCatalogRecord(
            id: failedID,
            displayName: "Bootstrap Broken",
            status: .failed,
            mdxFileName: "broken.mdx",
            hasMDD: false,
            dbPath: failedFolder.appendingPathComponent("index/dictionary.sqlite", isDirectory: false).path,
            sourceFolderPath: failedFolder.appendingPathComponent("source", isDirectory: true).path
        )
        _ = try catalogStore.upsert(record: failedRecord)

        let appState = AppState(catalogStore: catalogStore, importIndexer: .shared)
        await appState.bootstrap()

        #expect(FileManager.default.fileExists(atPath: failedFolder.path) == false)
        #expect(FileManager.default.fileExists(atPath: orphanFolder.path) == false)

        let records = try catalogStore.loadRecords()
        #expect(records.isEmpty)
    }

    private func makeCatalogStore() throws -> (DictionaryCatalogStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("appstate_import_flow_catalog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalogURL = root.appendingPathComponent("catalog.json", isDirectory: false)
        return (DictionaryCatalogStore(fileURL: catalogURL), root)
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMinimalMDX(at url: URL, entryKey: String, html: String) throws {
        let numberWidth = 8
        let header = #"<Dictionary GeneratedByEngineVersion="2.0" Encoding="UTF-8" Encrypted="No" StripKey="No" KeyCaseSensitive="No"></Dictionary>"#
        var headerBytes = Data(header.utf8)
        headerBytes.append(0x00)

        let keyPayload = packedUInt(0, width: numberWidth)
            + Data(entryKey.utf8)
            + Data([0x00])

        let keyBlockCompressed = makeStoredBlock(from: keyPayload)

        let keyInfoRaw = packedUInt(1, width: numberWidth)
            + packedUInt(1, width: 2)
            + Data("a".utf8)
            + Data([0x00])
            + packedUInt(1, width: 2)
            + Data("a".utf8)
            + Data([0x00])
            + packedUInt(UInt64(keyBlockCompressed.count), width: numberWidth)
            + packedUInt(UInt64(keyPayload.count), width: numberWidth)

        let keyInfoCompressedBody = try compressZlib(keyInfoRaw)
        let keyInfoCompressed = Data([0x02, 0x00, 0x00, 0x00])
            + packedUInt(UInt64(MDictCodec.adler32(keyInfoRaw)), width: 4)
            + keyInfoCompressedBody

        let numbersBlock = packedUInt(1, width: numberWidth)
            + packedUInt(1, width: numberWidth)
            + packedUInt(UInt64(keyInfoRaw.count), width: numberWidth)
            + packedUInt(UInt64(keyInfoCompressed.count), width: numberWidth)
            + packedUInt(UInt64(keyBlockCompressed.count), width: numberWidth)

        let recordPayload = Data(html.utf8)
        let recordBlockCompressed = makeStoredBlock(from: recordPayload)

        let recordHeader = packedUInt(1, width: numberWidth)
            + packedUInt(1, width: numberWidth)
            + packedUInt(16, width: numberWidth)
            + packedUInt(UInt64(recordBlockCompressed.count), width: numberWidth)
            + packedUInt(UInt64(recordBlockCompressed.count), width: numberWidth)
            + packedUInt(UInt64(recordPayload.count), width: numberWidth)

        var fileData = Data()
        fileData += packedUInt(UInt64(headerBytes.count), width: 4)
        fileData += headerBytes
        fileData += packedUInt(UInt64(MDictCodec.adler32(headerBytes)), width: 4, littleEndian: true)

        fileData += numbersBlock
        fileData += packedUInt(UInt64(MDictCodec.adler32(numbersBlock)), width: 4)
        fileData += keyInfoCompressed
        fileData += keyBlockCompressed

        fileData += recordHeader
        fileData += recordBlockCompressed

        try fileData.write(to: url, options: .atomic)
    }

    private func makeStoredBlock(from payload: Data) -> Data {
        packedUInt(0, width: 4, littleEndian: true)
            + packedUInt(UInt64(MDictCodec.adler32(payload)), width: 4)
            + payload
    }

    private func compressZlib(_ input: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk {
                output.append(chunk)
            }
        }
        _ = try filter.write(input)
        try filter.finalize()
        return output
    }

    private func packedUInt(_ value: UInt64, width: Int, littleEndian: Bool = false) -> Data {
        var data = Data(count: width)
        for offset in 0..<width {
            let index = littleEndian ? offset : (width - 1 - offset)
            let byte = UInt8((value >> (offset * 8)) & 0xFF)
            data[index] = byte
        }
        return data
    }

    private func importedFolderPrefix(for baseName: String) -> String {
        let safeName = baseName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression)
            .lowercased()
        return "imported.\(safeName)."
    }

    private func importedDictionaryFolders(in root: URL, matchingPrefix prefix: String) throws -> [URL] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try contents.filter { url in
            guard url.lastPathComponent.hasPrefix(prefix) else { return false }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        }
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var result = lhs
    result.append(rhs)
    return result
}

private func += (lhs: inout Data, rhs: Data) {
    lhs.append(rhs)
}
