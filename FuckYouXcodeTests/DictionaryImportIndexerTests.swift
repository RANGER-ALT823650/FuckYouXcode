import Compression
import Foundation
import GRDB
import Testing
@testable import FuckYouXcode

struct DictionaryImportIndexerTests {
    @Test func importsFolderPackageAndSupportsInternalRebuild() async throws {
        let externalRoot = try makeTempDirectory(prefix: "indexer_external")
        defer { try? FileManager.default.removeItem(at: externalRoot) }

        let mdxURL = externalRoot
            .appendingPathComponent("dict", isDirectory: true)
            .appendingPathComponent("main.mdx", isDirectory: false)
        try FileManager.default.createDirectory(at: mdxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMDX(at: mdxURL, entryKey: "hello", html: "<div>Hello HTML</div>")

        let cssURL = externalRoot
            .appendingPathComponent("dict/assets", isDirectory: true)
            .appendingPathComponent("site.css", isDirectory: false)
        try FileManager.default.createDirectory(at: cssURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("body{color:red;}".utf8).write(to: cssURL, options: .atomic)

        let dictionaryID = "imported.test.indexer.folder.\(UUID().uuidString)"
        defer { clearImportedFolder(dictionaryID: dictionaryID) }

        let indexer = DictionaryImportIndexer.shared
        let first = try indexer.importDictionary(
            dictionaryID: dictionaryID,
            preferredDisplayName: "FolderPackage",
            sourceFolderURL: externalRoot,
            sourceFolderIsInternal: false
        )

        #expect(first.dictionaryID == dictionaryID)
        #expect(first.entryCount == 1)
        #expect(first.mdxRelativePath == "dict/main.mdx")
        #expect(FileManager.default.fileExists(atPath: first.dbURL.path))
        #expect(
            FileManager.default.fileExists(
                atPath: first.sourceFolderURL
                    .appendingPathComponent("dict/assets/site.css", isDirectory: false)
                    .path
            )
        )

        let service = try DictionaryService(dbQueue: DatabaseQueue(path: first.dbURL.path))
        let entries = try await service.lookupEntries("hello")

        #expect(entries.count == 1)
        #expect(entries.first?.html?.contains("Hello HTML") == true)

        try FileManager.default.removeItem(at: externalRoot)

        let rebuilt = try indexer.importDictionary(
            dictionaryID: dictionaryID,
            preferredDisplayName: "FolderPackage",
            sourceFolderURL: first.sourceFolderURL,
            sourceFolderIsInternal: true
        )

        #expect(rebuilt.dictionaryID == dictionaryID)
        #expect(rebuilt.dbURL.path == first.dbURL.path)
        #expect(rebuilt.mdxRelativePath == first.mdxRelativePath)
    }

    @Test func failsWhenMultipleMDXDetected() throws {
        let packageRoot = try makeTempDirectory(prefix: "indexer_multi_mdx")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        try makeMinimalMDX(
            at: packageRoot.appendingPathComponent("a.mdx", isDirectory: false),
            entryKey: "a",
            html: "<div>A</div>"
        )
        try makeMinimalMDX(
            at: packageRoot.appendingPathComponent("b.mdx", isDirectory: false),
            entryKey: "b",
            html: "<div>B</div>"
        )

        let dictionaryID = "imported.test.indexer.multi_mdx.\(UUID().uuidString)"
        defer { clearImportedFolder(dictionaryID: dictionaryID) }

        do {
            _ = try DictionaryImportIndexer.shared.importDictionary(
                dictionaryID: dictionaryID,
                preferredDisplayName: "Broken",
                sourceFolderURL: packageRoot,
                sourceFolderIsInternal: false
            )
            Issue.record("Expected import to fail for multiple mdx files")
        } catch {
            #expect(error.localizedDescription.contains("导入目录必须且仅能包含一个 .mdx 文件"))
        }
    }

    @Test func mddSelectionRequiresUniqueBasenameMatchWhenMultipleMDDExist() throws {
        let packageRoot = try makeTempDirectory(prefix: "indexer_mdd_match")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let mdxURL = packageRoot.appendingPathComponent("dict/main.mdx", isDirectory: false)
        try FileManager.default.createDirectory(at: mdxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMDX(at: mdxURL, entryKey: "run", html: "<div>Run</div>")

        let matchingMDD = packageRoot.appendingPathComponent("dict/main.mdd", isDirectory: false)
        let extraMDD = packageRoot.appendingPathComponent("dict/other.mdd", isDirectory: false)
        try Data("dummy".utf8).write(to: matchingMDD, options: .atomic)
        try Data("dummy".utf8).write(to: extraMDD, options: .atomic)

        let dictionaryID = "imported.test.indexer.mdd_match.\(UUID().uuidString)"
        defer { clearImportedFolder(dictionaryID: dictionaryID) }

        let result = try DictionaryImportIndexer.shared.importDictionary(
            dictionaryID: dictionaryID,
            preferredDisplayName: "MDDMatched",
            sourceFolderURL: packageRoot,
            sourceFolderIsInternal: false
        )

        #expect(result.mddRelativePath == "dict/main.mdd")
    }

    @Test func collectsSplitMDDByPrefixWhenMultipleMDDExist() async throws {
        let packageRoot = try makeTempDirectory(prefix: "indexer_mdd_split")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let mdxURL = packageRoot.appendingPathComponent("dict/main.mdx", isDirectory: false)
        try FileManager.default.createDirectory(at: mdxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMDX(at: mdxURL, entryKey: "jump", html: "<div>Jump</div>")

        try Data("dummy".utf8).write(to: packageRoot.appendingPathComponent("dict/main.2.mdd"), options: .atomic)
        try Data("dummy".utf8).write(to: packageRoot.appendingPathComponent("dict/main.1.mdd"), options: .atomic)
        try Data("dummy".utf8).write(to: packageRoot.appendingPathComponent("dict/unrelated.mdd"), options: .atomic)

        let dictionaryID = "imported.test.indexer.mdd_split.\(UUID().uuidString)"
        defer { clearImportedFolder(dictionaryID: dictionaryID) }

        let result = try DictionaryImportIndexer.shared.importDictionary(
            dictionaryID: dictionaryID,
            preferredDisplayName: "MDDSplit",
            sourceFolderURL: packageRoot,
            sourceFolderIsInternal: false
        )

        #expect(result.mddRelativePath == "dict/main.1.mdd")
        let service = try DictionaryService(dbQueue: DatabaseQueue(path: result.dbURL.path))
        let entries = try await service.lookupEntries("jump")
        #expect(entries.count == 1)
    }

    @Test func matchedMDDFailuresDoNotBlockImport() async throws {
        let packageRoot = try makeTempDirectory(prefix: "indexer_mdd_partial")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let mdxURL = packageRoot.appendingPathComponent("dict/main.mdx", isDirectory: false)
        try FileManager.default.createDirectory(at: mdxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMDX(at: mdxURL, entryKey: "walk", html: "<div>Walk</div>")

        try Data("broken-main".utf8).write(to: packageRoot.appendingPathComponent("dict/main.mdd"), options: .atomic)
        try Data("broken-split".utf8).write(to: packageRoot.appendingPathComponent("dict/main.1.mdd"), options: .atomic)

        let dictionaryID = "imported.test.indexer.mdd_partial.\(UUID().uuidString)"
        defer { clearImportedFolder(dictionaryID: dictionaryID) }

        let result = try DictionaryImportIndexer.shared.importDictionary(
            dictionaryID: dictionaryID,
            preferredDisplayName: "MDDPartial",
            sourceFolderURL: packageRoot,
            sourceFolderIsInternal: false
        )

        #expect(result.mddRelativePath == "dict/main.mdd")
        #expect(result.mddImportStats.assetCount == 0)
        #expect(result.mddImportStats.hasAssets == false)
        #expect(result.mddImportStats.warningMessage != nil)
        let service = try DictionaryService(dbQueue: DatabaseQueue(path: result.dbURL.path))
        let entries = try await service.lookupEntries("walk")
        #expect(entries.count == 1)
    }

    @Test func oversizedMDDIsSkippedAndImportStillSucceeds() async throws {
        let packageRoot = try makeTempDirectory(prefix: "indexer_mdd_oversize")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let mdxURL = packageRoot.appendingPathComponent("dict/main.mdx", isDirectory: false)
        try FileManager.default.createDirectory(at: mdxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMDX(at: mdxURL, entryKey: "big", html: "<div>Big</div>")

        let hugeMDD = packageRoot.appendingPathComponent("dict/main.1.mdd", isDirectory: false)
        try makeSparseFile(at: hugeMDD, size: 130 * 1024 * 1024)

        let dictionaryID = "imported.test.indexer.mdd_oversize.\(UUID().uuidString)"
        defer { clearImportedFolder(dictionaryID: dictionaryID) }

        let result = try DictionaryImportIndexer.shared.importDictionary(
            dictionaryID: dictionaryID,
            preferredDisplayName: "MDDOversize",
            sourceFolderURL: packageRoot,
            sourceFolderIsInternal: false
        )

        #expect(result.entryCount == 1)
        #expect(result.mddImportStats.assetCount == 0)
        #expect(result.mddImportStats.warningMessage != nil)
        let service = try DictionaryService(dbQueue: DatabaseQueue(path: result.dbURL.path))
        let entries = try await service.lookupEntries("big")
        #expect(entries.count == 1)
    }

    @Test func encryptedMDDIsSkippedAndImportStillSucceeds() async throws {
        let packageRoot = try makeTempDirectory(prefix: "indexer_mdd_encrypted")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let mdxURL = packageRoot.appendingPathComponent("dict/main.mdx", isDirectory: false)
        try FileManager.default.createDirectory(at: mdxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMDX(at: mdxURL, entryKey: "enc", html: "<div>Encrypted</div>")

        let encryptedMDD = packageRoot.appendingPathComponent("dict/main.mdd", isDirectory: false)
        try makeEncryptedMDD(at: encryptedMDD)

        let dictionaryID = "imported.test.indexer.mdd_encrypted.\(UUID().uuidString)"
        defer { clearImportedFolder(dictionaryID: dictionaryID) }

        let result = try DictionaryImportIndexer.shared.importDictionary(
            dictionaryID: dictionaryID,
            preferredDisplayName: "MDDEncrypted",
            sourceFolderURL: packageRoot,
            sourceFolderIsInternal: false
        )

        #expect(result.entryCount == 1)
        #expect(result.mddImportStats.assetCount == 0)
        #expect(result.mddImportStats.warningMessage != nil)
        let service = try DictionaryService(dbQueue: DatabaseQueue(path: result.dbURL.path))
        let entries = try await service.lookupEntries("enc")
        #expect(entries.count == 1)
    }

    @Test func multipleMDDWithoutUniqueMatchFails() throws {
        let packageRoot = try makeTempDirectory(prefix: "indexer_mdd_ambiguous")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let mdxURL = packageRoot.appendingPathComponent("dict/main.mdx", isDirectory: false)
        try FileManager.default.createDirectory(at: mdxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMDX(at: mdxURL, entryKey: "run", html: "<div>Run</div>")

        try Data("dummy".utf8).write(to: packageRoot.appendingPathComponent("dict/a.mdd"), options: .atomic)
        try Data("dummy".utf8).write(to: packageRoot.appendingPathComponent("dict/b.mdd"), options: .atomic)

        let dictionaryID = "imported.test.indexer.mdd_ambiguous.\(UUID().uuidString)"
        defer { clearImportedFolder(dictionaryID: dictionaryID) }

        do {
            _ = try DictionaryImportIndexer.shared.importDictionary(
                dictionaryID: dictionaryID,
                preferredDisplayName: "Ambiguous",
                sourceFolderURL: packageRoot,
                sourceFolderIsInternal: false
            )
            Issue.record("Expected import to fail for ambiguous mdd selection")
        } catch {
            #expect(error.localizedDescription.contains("检测到多个 .mdd 且无法唯一匹配"))
        }
    }

    @Test func rejectsImportWhenDirectoryContainsSymbolicLink() throws {
        let packageRoot = try makeTempDirectory(prefix: "indexer_symlink")
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let mdxURL = packageRoot.appendingPathComponent("dict/main.mdx", isDirectory: false)
        try FileManager.default.createDirectory(at: mdxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMDX(at: mdxURL, entryKey: "safe", html: "<div>Safe</div>")

        let outsideTarget = try makeTempDirectory(prefix: "indexer_symlink_target")
            .appendingPathComponent("external.css", isDirectory: false)
        try Data("body{}".utf8).write(to: outsideTarget, options: .atomic)

        let symlinkURL = packageRoot
            .appendingPathComponent("dict/assets", isDirectory: true)
            .appendingPathComponent("link.css", isDirectory: false)
        try FileManager.default.createDirectory(at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideTarget)

        let dictionaryID = "imported.test.indexer.symlink.\(UUID().uuidString)"
        defer {
            clearImportedFolder(dictionaryID: dictionaryID)
            try? FileManager.default.removeItem(at: outsideTarget.deletingLastPathComponent())
        }

        do {
            _ = try DictionaryImportIndexer.shared.importDictionary(
                dictionaryID: dictionaryID,
                preferredDisplayName: "SymlinkBlocked",
                sourceFolderURL: packageRoot,
                sourceFolderIsInternal: false
            )
            Issue.record("Expected import to fail when symbolic link exists")
        } catch {
            #expect(error.localizedDescription.contains("符号链接"))
        }
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func clearImportedFolder(dictionaryID: String) {
        if let dictionaryFolder = try? UserStoragePaths.dictionaryFolderURL(id: dictionaryID, createIfNeeded: false) {
            try? FileManager.default.removeItem(at: dictionaryFolder)
        }
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

    private func makeSparseFile(at url: URL, size: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    private func makeEncryptedMDD(at url: URL) throws {
        let header = #"<Library_Data GeneratedByEngineVersion="2.0" RequiredEngineVersion="2.0" Encrypted="2" Encoding="" Format=""></Library_Data>"#
        guard var headerBytes = header.data(using: .utf16LittleEndian) else {
            throw NSError(domain: "DictionaryImportIndexerTests", code: 1)
        }
        headerBytes.append(contentsOf: [0x00, 0x00])

        var fileData = Data()
        fileData += packedUInt(UInt64(headerBytes.count), width: 4)
        fileData += headerBytes
        fileData += packedUInt(UInt64(MDictCodec.adler32(headerBytes)), width: 4, littleEndian: true)

        try fileData.write(to: url, options: .atomic)
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
}

private func + (lhs: Data, rhs: Data) -> Data {
    var result = lhs
    result.append(rhs)
    return result
}

private func += (lhs: inout Data, rhs: Data) {
    lhs.append(rhs)
}
