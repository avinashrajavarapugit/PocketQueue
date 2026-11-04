import Foundation
@testable import PocketQueueCore
import SQLite3
import Testing

struct StoreTests {
    @Test func persistsAcrossIndependentConnectionsAndDeduplicates() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let url = try BookmarkURL.parse("https://example.com")
        let first = try await fixture.store.save(url: url, note: "Important", tags: ["swift"])
        let secondStore = BookmarkStore(databaseURL: fixture.databaseURL)
        let second = try await secondStore.save(url: url, note: "Must not overwrite", tags: [])
        #expect(first.inserted)
        #expect(!second.inserted)
        #expect(second.bookmark.id == first.bookmark.id)
        #expect(try await secondStore.all().first?.note == "Important")
    }

    @Test func concurrentWritersKeepEveryBookmark() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 24 {
                group.addTask {
                    let store = BookmarkStore(databaseURL: fixture.databaseURL)
                    let url = try BookmarkURL.parse("https://example.com/\(index)")
                    _ = try await store.save(url: url, note: "", tags: [])
                }
            }
            try await group.waitForAll()
        }
        #expect(try await fixture.store.all().count == 24)
    }

    @Test func concurrentDuplicateSavesAreIdempotent() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let url = try BookmarkURL.parse("https://example.com/shared")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 12 {
                group.addTask {
                    _ = try await BookmarkStore(databaseURL: fixture.databaseURL).save(url: url)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await fixture.store.all().count == 1)
    }

    @Test func enrichmentDoesNotOverwriteUserEditsOrResurrectDeletedItems() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let saved = try await fixture.store.save(url: BookmarkURL.parse("example.com"))
        try await fixture.store.update(id: saved.bookmark.id, change: .details(note: "Edited", tags: ["ios"]))
        try await fixture.store.update(id: saved.bookmark.id, change: .metadata(LinkMetadata(title: "Website")))
        let bookmarks = try await fixture.store.all()
        #expect(bookmarks.first?.note == "Edited")
        #expect(bookmarks.first?.title == "Website")
        try await fixture.store.delete(id: saved.bookmark.id)
        await #expect(throws: BookmarkError.missingBookmark) {
            try await fixture.store.update(id: saved.bookmark.id, change: .metadata(LinkMetadata(title: "Late")))
        }
        #expect(try await fixture.store.all().isEmpty)
    }

    @Test func flagsAndMetadataFailureSurviveReopen() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let saved = try await fixture.store.save(url: BookmarkURL.parse("example.com"))
        try await fixture.store.update(id: saved.bookmark.id, change: .favorite(true))
        try await fixture.store.update(id: saved.bookmark.id, change: .read(true))
        try await fixture.store.update(id: saved.bookmark.id, change: .metadataFailed("Offline"))
        let reopened = try await BookmarkStore(databaseURL: fixture.databaseURL).all()
        #expect(reopened.first?.isRead == true)
        #expect(reopened.first?.isFavorite == true)
        #expect(reopened.first?.metadataState == .failed)
        try await fixture.store.update(id: saved.bookmark.id, change: .retryMetadata)
        #expect(try await fixture.store.all().first?.metadataState == .pending)
    }

    @Test func futureDatabaseSchemaIsNotSilentlyReset() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        _ = try await fixture.store.all()
        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.databaseURL.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        await #expect(throws: BookmarkError.unsupportedDatabase(99)) { try await fixture.store.all() }
    }

    @Test func corruptDatabaseSurfacesAnError() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try Data("not a database".utf8).write(to: fixture.databaseURL)
        await #expect(throws: (any Error).self) { try await fixture.store.all() }
        #expect(try Data(contentsOf: fixture.databaseURL) == Data("not a database".utf8))
    }
}

struct StoreFixture: Sendable {
    let directory: URL
    let databaseURL: URL
    let store: BookmarkStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "PocketQueueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appending(path: "library.sqlite")
        store = BookmarkStore(databaseURL: databaseURL)
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not clean test fixture: \(error)")
        }
    }
}
