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

    private func makeTempDBURL(name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(name)_\(UUID().uuidString).sqlite")
    }
}
