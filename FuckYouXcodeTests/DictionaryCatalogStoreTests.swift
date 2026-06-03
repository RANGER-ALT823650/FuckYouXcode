import Foundation
import Testing
@testable import FuckYouXcode

struct DictionaryCatalogStoreTests {
    private func makeStore() throws -> (DictionaryCatalogStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("catalog_store_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let catalogURL = root.appendingPathComponent("catalog.json", isDirectory: false)
        return (DictionaryCatalogStore(fileURL: catalogURL), root)
    }

    @Test func persistsAndLoadsRecords() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = DictionaryCatalogRecord(
            id: "imported.demo.1",
            displayName: "Demo",
            status: .ready,
            mdxFileName: "dict/demo.mdx",
            mddFileName: "dict/assets/demo.mdd",
            hasMDD: true,
            dbPath: "/tmp/demo.sqlite",
            sourceFolderPath: "/tmp/source"
        )

        _ = try store.upsert(record: record)
        let loaded = try store.loadRecords()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == "imported.demo.1")
        #expect(loaded.first?.status == .ready)
        #expect(loaded.first?.hasMDD == true)
        #expect(loaded.first?.mdxFileName == "dict/demo.mdx")
        #expect(loaded.first?.mddFileName == "dict/assets/demo.mdd")
    }

    @Test func updatesStatusAndError() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = DictionaryCatalogRecord(
            id: "imported.demo.2",
            displayName: "Demo2",
            status: .indexing,
            mdxFileName: "demo2.mdx",
            hasMDD: false,
            dbPath: "/tmp/demo2.sqlite",
            sourceFolderPath: "/tmp/source2"
        )
        _ = try store.upsert(record: record)

        _ = try store.updateRecord(id: record.id) { current in
            current.status = .failed
            current.lastError = "test error"
        }

        let loaded = try store.record(id: record.id)
        #expect(loaded?.status == .failed)
        #expect(loaded?.lastError == "test error")
    }

    @Test func staleIndexingRecordsAreRecoveredAsFailed() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = DictionaryCatalogRecord(
            id: "imported.stale",
            displayName: "Stale",
            status: .indexing,
            mdxFileName: "stale.mdx",
            hasMDD: false,
            dbPath: "/tmp/stale.sqlite",
            sourceFolderPath: "/tmp/stale"
        )
        let active = DictionaryCatalogRecord(
            id: "imported.active",
            displayName: "Active",
            status: .indexing,
            mdxFileName: "active.mdx",
            hasMDD: false,
            dbPath: "/tmp/active.sqlite",
            sourceFolderPath: "/tmp/active"
        )

        _ = try store.upsert(record: stale)
        _ = try store.upsert(record: active)

        let updated = try store.markStaleIndexingRecordsAsFailed(
            activeIDs: ["imported.active"],
            message: "上次导入被系统中断，请重试。"
        )

        let staleAfter = updated.first(where: { $0.id == "imported.stale" })
        let activeAfter = updated.first(where: { $0.id == "imported.active" })

        #expect(staleAfter?.status == .failed)
        #expect(staleAfter?.lastError == "上次导入被系统中断，请重试。")
        #expect(activeAfter?.status == .indexing)
    }

    @Test func removeFailedRecords_removesAllFailed_keepsReadyAndIndexing() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let failedA = DictionaryCatalogRecord(
            id: "imported.failed.a",
            displayName: "FailedA",
            status: .failed,
            mdxFileName: "failed_a.mdx",
            hasMDD: false,
            dbPath: "/tmp/failed_a.sqlite",
            sourceFolderPath: "/tmp/failed_a"
        )
        let ready = DictionaryCatalogRecord(
            id: "imported.ready",
            displayName: "Ready",
            status: .ready,
            mdxFileName: "ready.mdx",
            hasMDD: false,
            dbPath: "/tmp/ready.sqlite",
            sourceFolderPath: "/tmp/ready"
        )
        let indexing = DictionaryCatalogRecord(
            id: "imported.indexing",
            displayName: "Indexing",
            status: .indexing,
            mdxFileName: "indexing.mdx",
            hasMDD: false,
            dbPath: "/tmp/indexing.sqlite",
            sourceFolderPath: "/tmp/indexing"
        )
        let failedB = DictionaryCatalogRecord(
            id: "imported.failed.b",
            displayName: "FailedB",
            status: .failed,
            mdxFileName: "failed_b.mdx",
            hasMDD: false,
            dbPath: "/tmp/failed_b.sqlite",
            sourceFolderPath: "/tmp/failed_b"
        )

        _ = try store.upsert(record: failedA)
        _ = try store.upsert(record: ready)
        _ = try store.upsert(record: indexing)
        _ = try store.upsert(record: failedB)

        let cleaned = try store.removeFailedRecords()

        #expect(cleaned.count == 2)
        #expect(cleaned.contains(where: { $0.id == ready.id }))
        #expect(cleaned.contains(where: { $0.id == indexing.id }))
        #expect(cleaned.contains(where: { $0.status == .failed }) == false)
    }

    @Test func removeFailedRecords_respectsExcludingIDs() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let failedKeep = DictionaryCatalogRecord(
            id: "imported.failed.keep",
            displayName: "FailedKeep",
            status: .failed,
            mdxFileName: "failed_keep.mdx",
            hasMDD: false,
            dbPath: "/tmp/failed_keep.sqlite",
            sourceFolderPath: "/tmp/failed_keep"
        )
        let failedRemove = DictionaryCatalogRecord(
            id: "imported.failed.remove",
            displayName: "FailedRemove",
            status: .failed,
            mdxFileName: "failed_remove.mdx",
            hasMDD: false,
            dbPath: "/tmp/failed_remove.sqlite",
            sourceFolderPath: "/tmp/failed_remove"
        )
        let ready = DictionaryCatalogRecord(
            id: "imported.ready.keep",
            displayName: "ReadyKeep",
            status: .ready,
            mdxFileName: "ready_keep.mdx",
            hasMDD: false,
            dbPath: "/tmp/ready_keep.sqlite",
            sourceFolderPath: "/tmp/ready_keep"
        )

        _ = try store.upsert(record: failedKeep)
        _ = try store.upsert(record: failedRemove)
        _ = try store.upsert(record: ready)

        let cleaned = try store.removeFailedRecords(excludingIDs: [failedKeep.id])

        #expect(cleaned.count == 2)
        #expect(cleaned.contains(where: { $0.id == failedKeep.id }))
        #expect(cleaned.contains(where: { $0.id == ready.id }))
        #expect(cleaned.contains(where: { $0.id == failedRemove.id }) == false)
    }
}
