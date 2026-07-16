import Foundation
import GRDB
import Testing
@testable import FuckYouXcode

struct WordGroupHierarchyTests {

    @Test
    func hierarchyMigrationPreservesExistingGroupsAsRootRegularGroups() async throws {
        let queue = try makeDatabaseQueue()
        try UserDB.makeMigrator(includeHierarchyMigration: false).migrate(queue)

        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO word_groups(name, note)
                VALUES ('Legacy Group', 'legacy note')
                """
            )
        }

        try UserDB.makeMigrator(includeHierarchyMigration: true).migrate(queue)

        let row = try await queue.read { db in
            return try Row.fetchOne(
                db,
                sql: """
                SELECT kind, parent_group_id AS parentGroupID, note
                     , archived_at AS archivedAt
                FROM word_groups
                WHERE name = 'Legacy Group'
                """
            )
        }

        #expect((row?["kind"] as String?) == "group")
        #expect((row?["parentGroupID"] as Int64?) == nil)
        #expect((row?["note"] as String?) == "legacy note")
        #expect((row?["archivedAt"] as Int64?) == nil)
    }

    @Test
    func createParentGroupLeavesExistingGroupsSelectable() async throws {
        let (service, _) = try makeUserDataService()

        let existingGroupID = try #require(
            await service.createWordGroup(baseName: "Existing", words: ["alpha"])
        )
        let parentGroupID = try #require(
            await service.createParentWordGroup(baseName: "Folder")
        )

        let rootGroups = await service.fetchRootWordGroups()
        let selectableGroups = await service.fetchSelectableWordGroups()

        #expect(rootGroups.contains(where: { $0.id == existingGroupID && $0.kind == .group }))
        #expect(rootGroups.contains(where: { $0.id == parentGroupID && $0.kind == .parent }))
        #expect(selectableGroups.contains(where: { $0.id == existingGroupID }))
        #expect(selectableGroups.contains(where: { $0.id == parentGroupID }) == false)
    }

    @Test
    func movingGroupUnderParentRemovesItFromRootAndShowsItInChildren() async throws {
        let (service, _) = try makeUserDataService()

        let childGroupID = try #require(
            await service.createWordGroup(baseName: "Child", words: ["alpha"])
        )
        let parentGroupID = try #require(
            await service.createParentWordGroup(baseName: "Folder")
        )

        let didMove = await service.moveWordGroup(
            groupID: childGroupID,
            toParentGroupID: parentGroupID
        )

        let rootGroups = await service.fetchRootWordGroups()
        let childGroups = await service.fetchChildWordGroups(parentGroupID: parentGroupID)

        #expect(didMove)
        #expect(rootGroups.contains(where: { $0.id == parentGroupID }))
        #expect(rootGroups.contains(where: { $0.id == childGroupID }) == false)
        #expect(childGroups.map(\.id) == [childGroupID])
        #expect(childGroups.first?.parentGroupID == parentGroupID)
    }

    @Test
    func archivingRootGroupHidesItFromMainListsAndShowsItInArchive() async throws {
        let (service, _) = try makeUserDataService()

        let groupID = try #require(
            await service.createWordGroup(baseName: "Archive Me", words: ["alpha"])
        )

        let didArchive = await service.archiveWordGroup(groupID: groupID)
        let rootGroups = await service.fetchRootWordGroups()
        let selectableGroups = await service.fetchSelectableWordGroups()
        let archivedGroups = await service.fetchArchivedWordGroups()
        let words = await service.fetchWords(inGroupID: groupID)
        let isRootVisible = rootGroups.contains { $0.id == groupID }
        let isSelectable = selectableGroups.contains { $0.id == groupID }
        let isArchived = archivedGroups.contains { group in
            group.id == groupID && group.kind == .group && group.archivedAt != nil
        }

        #expect(didArchive)
        #expect(!isRootVisible)
        #expect(!isSelectable)
        #expect(isArchived)
        #expect(words == ["alpha"])
    }

    @Test
    func archivingGroupRemovesFavoritesButPreservesHighlightsAndAnnotations() async throws {
        let (service, queue) = try makeUserDataService()

        let groupID = try #require(
            await service.createWordGroup(baseName: "Archive Me", words: ["alpha", "beta"])
        )

        try await queue.write { db in
            try db.execute(sql: "INSERT INTO favorites(word) VALUES ('alpha'), ('beta'), ('keep')")
            try db.execute(
                sql: """
                INSERT INTO highlights(entry_id, word, dictionary_id, field, start, length, color, note)
                VALUES (1, 'alpha', 'builtin.default', 'definition', 0, 5, 'yellow', 'marked')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO annotations(word, dictionary_id, entry_id, field, start, length, content)
                VALUES ('alpha', 'builtin.default', 1, 'definition', 0, 5, 'note')
                """
            )
        }

        let didArchive = await service.archiveWordGroup(groupID: groupID)
        let remainingFavorites = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT word FROM favorites ORDER BY word ASC")
        }
        let highlightCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM highlights WHERE word = 'alpha'") ?? 0
        }
        let annotationCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotations WHERE word = 'alpha'") ?? 0
        }

        #expect(didArchive)
        #expect(remainingFavorites == ["keep"])
        #expect(highlightCount == 1)
        #expect(annotationCount == 1)
    }

    @Test
    func restoringArchivedGroupReturnsItToOriginalPlaceAndRestoresFavorites() async throws {
        let (service, queue) = try makeUserDataService()

        let groupID = try #require(
            await service.createWordGroup(baseName: "Restore Me", words: ["alpha", "beta"])
        )
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO favorites(word) VALUES ('alpha'), ('beta'), ('keep')")
        }

        let didArchive = await service.archiveWordGroup(groupID: groupID)
        let favoritesAfterArchive = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT word FROM favorites ORDER BY word ASC")
        }

        let didRestore = await service.restoreWordGroupFromArchive(groupID: groupID)
        let rootGroups = await service.fetchRootWordGroups()
        let selectableGroups = await service.fetchSelectableWordGroups()
        let archivedGroups = await service.fetchArchivedWordGroups()
        let favoritesAfterRestore = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT word FROM favorites ORDER BY word ASC")
        }

        #expect(didArchive)
        #expect(favoritesAfterArchive == ["keep"])
        #expect(didRestore)
        #expect(rootGroups.contains(where: { $0.id == groupID }))
        #expect(selectableGroups.contains(where: { $0.id == groupID }))
        #expect(!archivedGroups.contains(where: { $0.id == groupID }))
        #expect(favoritesAfterRestore == ["alpha", "beta", "keep"])
    }

    @Test
    func archivingParentHidesNestedGroupsFromSelectableLists() async throws {
        let (service, queue) = try makeUserDataService()

        let childGroupID = try #require(
            await service.createWordGroup(baseName: "Child", words: ["alpha"])
        )
        let parentGroupID = try #require(
            await service.createParentWordGroup(baseName: "Folder")
        )
        _ = await service.moveWordGroup(groupID: childGroupID, toParentGroupID: parentGroupID)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO favorites(word) VALUES ('alpha'), ('keep')")
        }

        let didArchive = await service.archiveWordGroup(groupID: parentGroupID)
        let rootGroups = await service.fetchRootWordGroups()
        let selectableGroups = await service.fetchSelectableWordGroups()
        let archivedGroups = await service.fetchArchivedWordGroups()
        let archivedParentChildren = await service.fetchChildWordGroups(
            parentGroupID: parentGroupID,
            includeArchivedChildren: true
        )
        let isParentRootVisible = rootGroups.contains { $0.id == parentGroupID }
        let isChildSelectable = selectableGroups.contains { $0.id == childGroupID }
        let isParentArchived = archivedGroups.contains { group in
            group.id == parentGroupID && group.kind == .parent
        }
        let isChildIndividuallyArchived = archivedGroups.contains { $0.id == childGroupID }
        let remainingFavorites = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT word FROM favorites ORDER BY word ASC")
        }

        #expect(didArchive)
        #expect(!isParentRootVisible)
        #expect(!isChildSelectable)
        #expect(isParentArchived)
        #expect(!isChildIndividuallyArchived)
        #expect(archivedParentChildren.map(\.id) == [childGroupID])
        #expect(remainingFavorites == ["keep"])
    }

    @Test
    func restoringArchivedParentReturnsChildrenToSelectableListsAndRestoresFavorites() async throws {
        let (service, queue) = try makeUserDataService()

        let childGroupID = try #require(
            await service.createWordGroup(baseName: "Child", words: ["alpha"])
        )
        let parentGroupID = try #require(
            await service.createParentWordGroup(baseName: "Folder")
        )
        _ = await service.moveWordGroup(groupID: childGroupID, toParentGroupID: parentGroupID)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO favorites(word) VALUES ('alpha')")
        }

        let didArchive = await service.archiveWordGroup(groupID: parentGroupID)
        let favoritesAfterArchive = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT word FROM favorites ORDER BY word ASC")
        }

        let didRestore = await service.restoreWordGroupFromArchive(groupID: parentGroupID)
        let rootGroups = await service.fetchRootWordGroups()
        let selectableGroups = await service.fetchSelectableWordGroups()
        let archivedGroups = await service.fetchArchivedWordGroups()
        let favoritesAfterRestore = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT word FROM favorites ORDER BY word ASC")
        }

        #expect(didArchive)
        #expect(favoritesAfterArchive.isEmpty)
        #expect(didRestore)
        #expect(rootGroups.contains(where: { $0.id == parentGroupID }))
        #expect(selectableGroups.contains(where: { $0.id == childGroupID }))
        #expect(!archivedGroups.contains(where: { $0.id == parentGroupID }))
        #expect(favoritesAfterRestore == ["alpha"])
    }

    @Test
    func archivingChildGroupHidesItFromParentChildren() async throws {
        let (service, _) = try makeUserDataService()

        let childGroupID = try #require(
            await service.createWordGroup(baseName: "Child", words: ["alpha"])
        )
        let parentGroupID = try #require(
            await service.createParentWordGroup(baseName: "Folder")
        )
        _ = await service.moveWordGroup(groupID: childGroupID, toParentGroupID: parentGroupID)

        let didArchive = await service.archiveWordGroup(groupID: childGroupID)
        let visibleChildGroups = await service.fetchChildWordGroups(parentGroupID: parentGroupID)
        let archivedGroups = await service.fetchArchivedWordGroups()
        let isChildArchived = archivedGroups.contains { group in
            group.id == childGroupID && group.kind == .group
        }

        #expect(didArchive)
        #expect(visibleChildGroups.isEmpty)
        #expect(isChildArchived)
    }

    @Test
    func deletingParentWithPreserveReturnsChildrenToRoot() async throws {
        let (service, queue) = try makeUserDataService()

        let childGroupID = try #require(
            await service.createWordGroup(baseName: "Child", words: ["alpha"])
        )
        let parentGroupID = try #require(
            await service.createParentWordGroup(baseName: "Folder")
        )
        _ = await service.moveWordGroup(groupID: childGroupID, toParentGroupID: parentGroupID)

        await service.deleteParentWordGroup(parentGroupID: parentGroupID, preserveChildren: true)

        let rootGroups = await service.fetchRootWordGroups()
        let childGroups = await service.fetchChildWordGroups(parentGroupID: parentGroupID)
        let parentGroupIDInDB = try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT parent_group_id AS parentGroupID
                FROM word_groups
                WHERE id = ?
                """,
                arguments: [childGroupID]
            )
            return row?["parentGroupID"] as Int64?
        }

        #expect(rootGroups.contains(where: { $0.id == childGroupID && $0.parentGroupID == nil }))
        #expect(rootGroups.contains(where: { $0.id == parentGroupID }) == false)
        #expect(childGroups.isEmpty)
        #expect(parentGroupIDInDB == nil)
    }

    @Test
    func deletingParentWithoutPreserveDeletesOnlyNestedGroupsAndPurgesTheirCollections() async throws {
        let (service, queue) = try makeUserDataService()

        let keepGroupID = try #require(
            await service.createWordGroup(baseName: "Keep", words: ["keep"])
        )
        let deleteGroupID = try #require(
            await service.createWordGroup(baseName: "Delete", words: ["purge"])
        )
        let parentGroupID = try #require(
            await service.createParentWordGroup(baseName: "Folder")
        )
        _ = await service.moveWordGroup(groupID: deleteGroupID, toParentGroupID: parentGroupID)

        try await queue.write { db in
            try db.execute(sql: "INSERT INTO favorites(word) VALUES ('keep')")
            try db.execute(sql: "INSERT INTO favorites(word) VALUES ('purge')")
        }

        await service.deleteParentWordGroup(parentGroupID: parentGroupID, preserveChildren: false)

        let rootGroups = await service.fetchRootWordGroups()
        let selectableGroups = await service.fetchSelectableWordGroups()
        let remainingFavorites = try await queue.read { db in
            return try String.fetchAll(db, sql: "SELECT word FROM favorites ORDER BY word ASC")
        }

        #expect(rootGroups.contains(where: { $0.id == keepGroupID }))
        #expect(rootGroups.contains(where: { $0.id == deleteGroupID }) == false)
        #expect(rootGroups.contains(where: { $0.id == parentGroupID }) == false)
        #expect(selectableGroups.contains(where: { $0.id == keepGroupID }))
        #expect(selectableGroups.contains(where: { $0.id == deleteGroupID }) == false)
        #expect(remainingFavorites == ["keep"])
    }

    private func makeUserDataService() throws -> (UserDataService, DatabaseQueue) {
        let queue = try makeDatabaseQueue()
        try UserDB.makeMigrator(includeHierarchyMigration: true).migrate(queue)
        let userDB = UserDB(dbQueue: queue)
        return (UserDataService(db: userDB), queue)
    }

    private func makeDatabaseQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: ":memory:")
        try queue.inDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
        }
        return queue
    }
}

struct DictionaryInlineLinkParserTests {
    @Test
    func parsesInlineDictionaryLinksIntoDisplayTextAndRanges() {
        let result = DictionaryInlineLinkParser.parse("可以顺带记 [[rupture]] 和 [[ disrupt ]]。")

        #expect(result.displayText == "可以顺带记 rupture 和 disrupt。")
        #expect(result.links.map(\.word) == ["rupture", "disrupt"])
        #expect((result.displayText as NSString).substring(with: result.links[0].range) == "rupture")
        #expect((result.displayText as NSString).substring(with: result.links[1].range) == "disrupt")
    }

    @Test
    func leavesUnclosedInlineDictionaryLinkAsLiteralText() {
        let result = DictionaryInlineLinkParser.parse("来自 [[rupture 和 abrupt")

        #expect(result.displayText == "来自 [[rupture 和 abrupt")
        #expect(result.links.isEmpty)
    }
}
