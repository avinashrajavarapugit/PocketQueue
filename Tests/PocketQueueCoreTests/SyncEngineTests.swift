import Foundation
@testable import PocketQueueCore
import Testing

struct SyncEngineTests {
    @Test func lostResponseRetriesTheSameOperationAndPreservesOfflineData() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        _ = try await store.save(url: BookmarkURL.parse("example.com"), note: "Offline")
        let pending = try #require(try await store.pendingChanges().first)
        let remote = SyncRemoteFixture(failFirstResponse: true)
        let engine = BookmarkSyncEngine(store: store, remote: remote)
        await #expect(throws: URLError.self) { try await engine.synchronize() }
        #expect(try await store.pendingChanges().first?.operationID == pending.operationID)
        #expect(try await store.all().first?.note == "Offline")
        let result = try await engine.synchronize()
        #expect(result.pendingCount == 0)
        #expect(await remote.receivedOperations == [pending.operationID, pending.operationID])
    }

    @Test func syncFetchesAllPagesAndDoesNotPushKnownConflicts() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        let saved = try await store.save(url: BookmarkURL.parse("example.com/local"), note: "Local")
        let pending = try #require(try await store.pendingChanges().first)
        var other = saved.bookmark
        other.note = "Cloud"
        let conflict = RemoteBookmark(bookmark: other, version: 2)
        try await store.acknowledge(pending, result: .init(status: .conflict, record: conflict))
        let another = try RemoteBookmark(bookmark: Bookmark(url: BookmarkURL.parse("example.com/another")), version: 1)
        let remote = SyncRemoteFixture(pages: [
            BookmarkPage(records: [conflict], endCursor: "page-two", hasNextPage: true),
            BookmarkPage(records: [another]),
        ])
        let result = try await BookmarkSyncEngine(store: store, remote: remote).synchronize()
        #expect(result.conflictCount == 1)
        #expect(result.pendingCount == 1)
        #expect(await remote.receivedOperations.isEmpty)
        #expect(await remote.cursors == [nil, "page-two"])
        #expect(try await store.all().count == 2)
    }

    @Test func aNonAdvancingPageCursorIsAnExplicitFailure() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try await fixture.store.activateAccount(UUID())
        let record = try RemoteBookmark(bookmark: Bookmark(url: BookmarkURL.parse("example.com")), version: 1)
        let page = BookmarkPage(records: [record], endCursor: "same", hasNextPage: true)
        let remote = SyncRemoteFixture(pages: [page, page])
        await #expect(throws: SyncError.invalidResponse) {
            try await BookmarkSyncEngine(store: store, remote: remote).synchronize()
        }
    }
}

private actor SyncRemoteFixture: CloudBookmarkTransport {
    private var failFirstResponse: Bool
    private var pages: [BookmarkPage]
    private(set) var receivedOperations: [UUID] = []
    private(set) var cursors: [String?] = []

    init(failFirstResponse: Bool = false, pages: [BookmarkPage] = [BookmarkPage(records: [])]) {
        self.failFirstResponse = failFirstResponse
        self.pages = pages
    }

    func apply(_ change: PendingChange) throws -> MutationResult {
        receivedOperations.append(change.operationID)
        if failFirstResponse {
            failFirstResponse = false
            throw URLError(.networkConnectionLost)
        }
        return .init(status: .applied, record: .init(
            bookmark: change.bookmark, version: change.baseVersion + 1, isDeleted: change.isDeleted
        ))
    }

    func fetchPage(after cursor: String?) -> BookmarkPage {
        cursors.append(cursor)
        return pages.removeFirst()
    }
}
