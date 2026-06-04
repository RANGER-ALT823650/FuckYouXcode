import Foundation
import GRDB
import Testing
@testable import FuckYouXcode

struct UserDataServiceTests {
    @Test func toggleFavoriteReturnsPersistedState() async throws {
        let dbURL = makeTempDBURL(name: "user_data_service")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
        }

        let queue = try DatabaseQueue(path: dbURL.path)
        let userDB = UserDB(dbQueue: queue, shouldIncludeHierarchyMigration: false)
        try await userDB.prepareIfNeeded()

        let service = UserDataService(db: userDB)

        let firstToggle = try await service.toggleFavorite(word: "hello")
        #expect(firstToggle == true)
        #expect(await service.isFavorite(word: "hello") == true)

        let secondToggle = try await service.toggleFavorite(word: "hello")
        #expect(secondToggle == false)
        #expect(await service.isFavorite(word: "hello") == false)
    }

    @Test func addFavoriteIsIdempotent() async throws {
        let dbURL = makeTempDBURL(name: "user_data_service_add")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
        }

        let queue = try DatabaseQueue(path: dbURL.path)
        let userDB = UserDB(dbQueue: queue, shouldIncludeHierarchyMigration: false)
        try await userDB.prepareIfNeeded()

        let service = UserDataService(db: userDB)

        let firstAdd = try await service.addFavorite(word: "hello")
        let secondAdd = try await service.addFavorite(word: "hello")
        let favoriteCount = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM favorites WHERE word = ?",
                arguments: ["hello"]
            ) ?? 0
        }

        #expect(firstAdd == true)
        #expect(secondAdd == false)
        #expect(await service.isFavorite(word: "hello") == true)
        #expect(favoriteCount == 1)
    }

    private func makeTempDBURL(name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(name)_\(UUID().uuidString).sqlite")
    }
}
