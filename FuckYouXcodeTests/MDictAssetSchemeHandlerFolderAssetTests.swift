import Foundation
import GRDB
import Testing
@testable import FuckYouXcode

struct MDictAssetSchemeHandlerFolderAssetTests {
    @Test func folderAssetExactPathWinsOverMDD() throws {
        let root = try makeTempDirectory(prefix: "scheme_folder_exact")
        defer { try? FileManager.default.removeItem(at: root) }

        let cssFile = root.appendingPathComponent("css/main.css", isDirectory: false)
        try FileManager.default.createDirectory(at: cssFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("folder-body".utf8).write(to: cssFile, options: .atomic)

        let service = try makeServiceWithMDDAsset(
            pathNorm: "css/main.css",
            originalKey: "CSS/Main.CSS",
            data: Data("mdd-body".utf8),
            mime: "text/css"
        )

        let blob = try MDictAssetSchemeHandler.resolveAssetBlob(
            path: "css/main.css",
            sourceFolderURL: root,
            mdxRelativePath: nil,
            service: service
        )

        #expect(blob?.data == Data("folder-body".utf8))
    }

    @Test func folderAssetCaseInsensitiveFallbackHits() throws {
        let root = try makeTempDirectory(prefix: "scheme_folder_case")
        defer { try? FileManager.default.removeItem(at: root) }

        let cssFile = root.appendingPathComponent("CSS/Main.CSS", isDirectory: false)
        try FileManager.default.createDirectory(at: cssFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("folder-case".utf8).write(to: cssFile, options: .atomic)

        let service = try makeServiceWithMDDAsset()

        let blob = try MDictAssetSchemeHandler.resolveAssetBlob(
            path: "css/main.css",
            sourceFolderURL: root,
            mdxRelativePath: nil,
            service: service
        )

        #expect(blob?.data == Data("folder-case".utf8))
        #expect(blob?.mimeType == "text/css")
    }

    @Test func folderAssetSupportsMdxSubdirectoryFallback() throws {
        let root = try makeTempDirectory(prefix: "scheme_folder_subdir")
        defer { try? FileManager.default.removeItem(at: root) }

        let jsFile = root.appendingPathComponent("dict/assets/site.js", isDirectory: false)
        try FileManager.default.createDirectory(at: jsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("console.log('ok')".utf8).write(to: jsFile, options: .atomic)

        let service = try makeServiceWithMDDAsset()

        let blob = try MDictAssetSchemeHandler.resolveAssetBlob(
            path: "assets/site.js",
            sourceFolderURL: root,
            mdxRelativePath: "dict/main.mdx",
            service: service
        )

        #expect(blob?.data == Data("console.log('ok')".utf8))
    }

    @Test func traversalPathIsRejected() throws {
        let root = try makeTempDirectory(prefix: "scheme_folder_traversal")
        defer { try? FileManager.default.removeItem(at: root) }

        let secret = root.appendingPathComponent("secret.txt", isDirectory: false)
        try Data("secret".utf8).write(to: secret, options: .atomic)

        let service = try makeServiceWithMDDAsset()

        let blob = try MDictAssetSchemeHandler.resolveAssetBlob(
            path: "../secret.txt",
            sourceFolderURL: root,
            mdxRelativePath: nil,
            service: service
        )

        #expect(blob == nil)
    }

    @Test func symbolicLinkEscapingRootIsRejected() throws {
        let root = try makeTempDirectory(prefix: "scheme_folder_symlink")
        defer { try? FileManager.default.removeItem(at: root) }

        let outsideRoot = try makeTempDirectory(prefix: "scheme_folder_outside")
        defer { try? FileManager.default.removeItem(at: outsideRoot) }

        let outsideFile = outsideRoot.appendingPathComponent("outside.css", isDirectory: false)
        try Data("outside".utf8).write(to: outsideFile, options: .atomic)

        let symlink = root.appendingPathComponent("css/main.css", isDirectory: false)
        try FileManager.default.createDirectory(at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideFile)

        let service = try makeServiceWithMDDAsset()

        let blob = try MDictAssetSchemeHandler.resolveAssetBlob(
            path: "css/main.css",
            sourceFolderURL: root,
            mdxRelativePath: nil,
            service: service
        )

        #expect(blob == nil)
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeServiceWithMDDAsset(
        pathNorm: String? = nil,
        originalKey: String? = nil,
        data: Data? = nil,
        mime: String? = nil
    ) throws -> DictionaryService {
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scheme_handler_db_\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE mdd_asset_index(
              path_norm TEXT PRIMARY KEY,
              original_key TEXT NOT NULL,
              data BLOB NOT NULL,
              mime TEXT NOT NULL
            );
            """)

            if let pathNorm, let originalKey, let data, let mime {
                try db.execute(
                    sql: "INSERT INTO mdd_asset_index(path_norm, original_key, data, mime) VALUES (?, ?, ?, ?);",
                    arguments: [pathNorm, originalKey, data, mime]
                )
            }
        }

        return try DictionaryService(dbQueue: queue)
    }
}
