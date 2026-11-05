import Foundation
@testable import PocketQueueCore
import SQLite3
import Testing

struct SyncStoreTests {
    @Test func resolvingAStaleConflictSnapshotCannotOverwriteAnUnseenCloudVersion() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        let saved = try await store.save(url: BookmarkURL.parse("example.com/stale-conflict"), note: "Local")
        var cloud = saved.bookmark
        cloud.note = "First cloud edit"
        try await store.integrate([.init(bookmark: cloud, version: 1)])
        cloud.note = "Unseen cloud edit"
        try await store.integrate([.init(bookmark: cloud, version: 2)])
        await #expect(throws: SyncError.conflictChanged) {
            try await store.resolveConflict(saved.bookmark.id, using: .keepDevice, expectedRemoteVersion: 1)
        }
        #expect(try await store.pendingChanges().first?.bookmark.note == "Local")
        #expect(try await store.conflicts().first?.remote?.bookmark.note == "Unseen cloud edit")
        try await store.resolveConflict(saved.bookmark.id, using: .keepDevice, expectedRemoteVersion: 2)
        #expect(try await store.pendingChanges().first?.baseVersion == 2)
    }

    @Test func identicalConcurrentContentDoesNotRequireAConflictChoice() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        let saved = try await store.save(url: BookmarkURL.parse("example.com/identical"), note: "Same intent")
        let pending = try #require(try await store.pendingChanges().first)
        try await store.acknowledge(pending, result: .init(
            status: .conflict, record: .init(bookmark: saved.bookmark, version: 2)
        ))
        #expect(try await store.pendingChanges().isEmpty)
        #expect(try await store.conflicts().isEmpty)
        try await store.update(id: saved.bookmark.id, change: .favorite(true))
        let latest = try #require(try await store.all().first)
        try await store.integrate([.init(bookmark: latest, version: 3)])
        #expect(try await store.pendingChanges().isEmpty)
        #expect(try await store.conflicts().isEmpty)
    }

    @Test func guestDataRequiresExplicitImportAndAccountCachesAreIsolated() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        _ = try await fixture.store.save(url: BookmarkURL.parse("example.com/guest"), note: "On device only")
        let accountA = UUID()
        let storeA = try await fixture.store.activateAccount(accountA)
        #expect(try await storeA.all().isEmpty)
        #expect(try await storeA.importGuestBookmarks() == 1)
        #expect(try await storeA.pendingChanges().count == 1)
        #expect(try await storeA.importGuestBookmarks() == 0)
        let storeB = try await storeA.activateAccount(UUID())
        #expect(try await storeB.all().isEmpty)
        await #expect(throws: SyncError.accountChanged) {
            try await storeA.save(url: BookmarkURL.parse("example.com/stale-share"))
        }
        await #expect(throws: SyncError.accountChanged) { try await fixture.store.all() }
        let restoredA = try await storeB.activateAccount(accountA)
        #expect(try await restoredA.all().first?.note == "On device only")
        let guest = try await restoredA.signOutAndRemoveAccountCache()
        #expect(try await guest.all().count == 1)
        let clearedA = try await guest.activateAccount(accountA)
        #expect(try await clearedA.all().isEmpty)
        #expect(try await clearedA.pendingChanges().isEmpty)
    }

    @Test func outboxSurvivesReopeningAndCoalescesLocalEdits() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let account = UUID()
        let store = try await fixture.store.activateAccount(account)
        let saved = try await store.save(url: BookmarkURL.parse("example.com"))
        let first = try #require(try await store.pendingChanges().first)
        try await store.update(id: saved.bookmark.id, change: .details(note: "Latest", tags: ["swift"]))
        let reopened = BookmarkStore(databaseURL: fixture.databaseURL, accountID: account)
        let pending = try await reopened.pendingChanges()
        #expect(pending.count == 1)
        #expect(pending.first?.bookmark.note == "Latest")
        #expect(pending.first?.operationID != first.operationID)
        #expect(pending.first?.baseVersion == 0)
        #expect(try BookmarkStore.activeAccountID(databaseURL: fixture.databaseURL) == account)
    }

    @Test func lateAcknowledgementPreservesNewerEditAndDeletion() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        let saved = try await store.save(url: BookmarkURL.parse("example.com"))
        let first = try #require(try await store.pendingChanges().first)
        try await store.update(id: saved.bookmark.id, change: .details(note: "Edited during request", tags: []))
        try await store.acknowledge(first, result: .init(
            status: .applied, record: .init(bookmark: first.bookmark, version: 1)
        ))
        #expect(try await store.all().first?.note == "Edited during request")
        let second = try #require(try await store.pendingChanges().first)
        #expect(second.baseVersion == 1)
        try await store.delete(id: saved.bookmark.id)
        try await store.acknowledge(second, result: .init(
            status: .applied, record: .init(bookmark: second.bookmark, version: 2)
        ))
        #expect(try await store.all().isEmpty)
        #expect(try await store.pendingChanges().first?.isDeleted == true)
        #expect(try await store.pendingChanges().first?.baseVersion == 2)
    }

    @Test func conflictsRetainBothVersionsUntilExplicitResolution() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        let saved = try await store.save(url: BookmarkURL.parse("example.com"), note: "My edit")
        let pending = try #require(try await store.pendingChanges().first)
        var cloud = saved.bookmark
        cloud.note = "Another device"
        try await store.acknowledge(pending, result: .init(
            status: .conflict, record: .init(bookmark: cloud, version: 3)
        ))
        let conflict = try #require(try await store.conflicts().first)
        #expect(conflict.local.bookmark.note == "My edit")
        #expect(conflict.remote?.bookmark.note == "Another device")
        try await store.resolveConflict(saved.bookmark.id, using: .keepDevice)
        #expect(try await store.conflicts().isEmpty)
        let kept = try #require(try await store.pendingChanges().first)
        #expect(kept.baseVersion == 3)
        #expect(kept.operationID != pending.operationID)
        #expect(kept.bookmark.note == "My edit")
        try await store.acknowledge(kept, result: .init(
            status: .conflict, record: .init(bookmark: cloud, version: 4)
        ))
        try await store.resolveConflict(saved.bookmark.id, using: .useCloud)
        #expect(try await store.pendingChanges().isEmpty)
        #expect(try await store.all().first?.note == "Another device")
    }

    @Test func duplicateURLResolutionAdoptsCanonicalServerIdentity() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        let saved = try await store.save(url: BookmarkURL.parse("example.com"), note: "Keep my notes")
        let cloud = Bookmark(url: saved.bookmark.url, note: "Existing cloud bookmark")
        try await store.integrate([.init(bookmark: cloud, version: 2)])
        #expect(try await store.conflicts().count == 1)
        try await store.resolveConflict(saved.bookmark.id, using: .keepDevice)
        #expect(try await store.all().first?.id == cloud.id)
        #expect(try await store.all().first?.note == "Keep my notes")
        #expect(try await store.pendingChanges().first?.baseVersion == 2)
    }

    @Test func remoteTombstonesApplyButDoNotSilentlyDeletePendingEdits() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        let bookmark = try Bookmark(url: BookmarkURL.parse("example.com"))
        try await store.integrate([.init(bookmark: bookmark, version: 1)])
        try await store.update(id: bookmark.id, change: .details(note: "Offline edit", tags: []))
        try await store.integrate([.init(bookmark: bookmark, version: 2, isDeleted: true)])
        #expect(try await store.all().first?.note == "Offline edit")
        #expect(try await store.conflicts().first?.remote?.isDeleted == true)
        try await store.resolveConflict(bookmark.id, using: .useCloud)
        #expect(try await store.all().isEmpty)
        let restored = try await store.save(url: bookmark.url, note: "Restore")
        #expect(restored.bookmark.id == bookmark.id)
        #expect(try await store.pendingChanges().first?.baseVersion == 2)
    }

    @Test func staleResponsesCannotUndoConflictResolutionOrCrossAccounts() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        let saved = try await store.save(url: BookmarkURL.parse("example.com"), note: "Original")
        let old = try #require(try await store.pendingChanges().first)
        var remote = saved.bookmark
        remote.note = "Version five"
        try await store.acknowledge(old, result: .init(status: .conflict, record: .init(bookmark: remote, version: 5)))
        try await store.resolveConflict(saved.bookmark.id, using: .useCloud)
        try await store.update(id: saved.bookmark.id, change: .details(note: "Edit version five", tags: []))
        try await store.acknowledge(
            old,
            result: .init(status: .applied, record: .init(bookmark: saved.bookmark, version: 1))
        )
        #expect(try await store.pendingChanges().first?.baseVersion == 5)
        #expect(try await store.all().first?.note == "Edit version five")
        _ = try await store.activateAccount(UUID())
        await #expect(throws: SyncError.accountChanged) {
            try await store.acknowledge(
                old,
                result: .init(status: .applied, record: .init(bookmark: saved.bookmark, version: 1))
            )
        }
    }

    @Test func versionOneGuestLibraryMigratesWithoutLosingItsBookmark() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let bookmark = try Bookmark(url: BookmarkURL.parse("example.com/legacy"), note: "Keep this")
        var database: OpaquePointer?
        try #require(sqlite3_open(fixture.databaseURL.path, &database) == SQLITE_OK)
        try #require(sqlite3_exec(database, """
        CREATE TABLE bookmarks (id TEXT PRIMARY KEY NOT NULL, url TEXT UNIQUE NOT NULL, created_at REAL NOT NULL, payload BLOB NOT NULL);
        PRAGMA user_version=1;
        """, nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(database, "INSERT INTO bookmarks VALUES(?,?,?,?)", -1, &statement, nil) ==
            SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, bookmark.id.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, bookmark.url.absoluteString, -1, transient)
        sqlite3_bind_double(statement, 3, bookmark.createdAt.timeIntervalSince1970)
        let data = try JSONEncoder().encode(bookmark)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) }
        try #require(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
        sqlite3_close(database)
        #expect(try await fixture.store.all() == [bookmark])
        let cloud = try await fixture.store.activateAccount(UUID())
        #expect(try await cloud.all().isEmpty)
    }
}
