import Foundation
@testable import PocketQueueCore
import Testing

@MainActor
struct LibraryModelTests {
    @Test func saveIsDurableBeforeAnyMetadataFetch() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let metadata = RecordingMetadataClient()
        let model = LibraryModel(store: fixture.store, metadata: metadata)
        #expect(await model.save("example.com", note: "My note"))
        #expect(await metadata.calls == 0)
        #expect(try await fixture.store.all().first?.note == "My note")
        #expect(model.bookmarks.first?.metadataState == .pending)
    }

    @Test func failedPreviewKeepsBookmarkAndRetryRecovers() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let metadata = RecordingMetadataClient()
        let model = LibraryModel(store: fixture.store, metadata: metadata)
        #expect(await model.save("example.com"))
        await metadata.setFailure(true)
        await model.refresh()
        #expect(model.bookmarks.count == 1)
        #expect(model.bookmarks.first?.metadataState == .failed)
        let bookmark = try #require(model.bookmarks.first)
        await metadata.setFailure(false)
        #expect(await model.update(bookmark.id, change: .retryMetadata))
        await model.refresh()
        #expect(model.bookmarks.first?.metadataState == .ready)
        #expect(model.bookmarks.first?.title == "A good read")
    }

    @Test func searchAndFiltersReflectMutations() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let model = LibraryModel(store: fixture.store, metadata: RecordingMetadataClient())
        #expect(await model.save("example.com", note: "Actors", tags: ["swift"]))
        let bookmark = try #require(model.bookmarks.first)
        model.searchText = "swift actors"
        #expect(model.visibleBookmarks.count == 1)
        model.filter = .favorites
        #expect(model.visibleBookmarks.isEmpty)
        #expect(await model.update(bookmark.id, change: .favorite(true)))
        #expect(model.visibleBookmarks.count == 1)
        #expect(await model.update(bookmark.id, change: .read(true)))
        model.filter = .unread
        #expect(model.visibleBookmarks.isEmpty)
        model.filter = .read
        #expect(model.visibleBookmarks.count == 1)
        #expect(await model.delete(bookmark.id))
        #expect(model.visibleBookmarks.isEmpty)
    }

    @Test func invalidInputProducesVisibleErrorWithoutSaving() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let model = LibraryModel(store: fixture.store, metadata: RecordingMetadataClient())
        #expect(await !model.save("javascript:alert(1)"))
        #expect(model.errorMessage != nil)
        #expect(model.bookmarks.isEmpty)
    }

    @Test func duplicateSavePreservesNotes() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let model = LibraryModel(store: fixture.store, metadata: RecordingMetadataClient())
        #expect(await model.save("example.com", note: "Original"))
        #expect(await model.save("https://example.com/", note: "Replacement"))
        #expect(model.bookmarks.count == 1)
        #expect(model.bookmarks.first?.note == "Original")
        #expect(model.notice == "This link is already saved.")
    }

    @Test func storageFailuresAreNotSuccessShaped() async {
        let model = LibraryModel(store: FailingStore(), metadata: RecordingMetadataClient())
        #expect(await !model.save("example.com"))
        #expect(model.errorMessage != nil)
        #expect(!model.isSaving)
        await model.load()
        #expect(!model.isLoading)
    }

    @Test func enrichmentHasAtMostThreeConcurrentRequests() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let metadata = ConcurrencyMetadataClient()
        let model = LibraryModel(store: fixture.store, metadata: metadata)
        for index in 0 ..< 8 {
            #expect(await model.save("https://example.com/\(index)"))
        }
        await model.refresh()
        #expect(await metadata.peakConcurrency == 3)
        #expect(model.bookmarks.allSatisfy { $0.metadataState == .ready })
    }

    @Test func cancellingEnrichmentKeepsTheDurableBookmarkPending() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let metadata = CancellableMetadataClient()
        let model = LibraryModel(store: fixture.store, metadata: metadata)
        #expect(await model.save("example.com"))
        let refresh = Task { await model.refresh() }
        await metadata.waitUntilStarted()
        refresh.cancel()
        await refresh.value
        let saved = try await fixture.store.all()
        #expect(saved.count == 1)
        #expect(saved.first?.metadataState == .pending)
        #expect(saved.first?.metadataMessage == nil)
    }
}

private actor ConcurrencyMetadataClient: MetadataFetching {
    private var active = 0
    private(set) var peakConcurrency = 0

    func fetch(_: URL) async throws -> LinkMetadata {
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(25))
        return LinkMetadata(title: "A good read")
    }
}

private actor CancellableMetadataClient: MetadataFetching {
    private var started = false
    private var waiting: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { waiting = $0 }
    }

    func fetch(_: URL) async throws -> LinkMetadata {
        started = true
        waiting?.resume()
        waiting = nil
        try await Task.sleep(for: .seconds(60))
        return LinkMetadata(title: "Should not finish")
    }
}

private actor RecordingMetadataClient: MetadataFetching {
    private(set) var calls = 0
    private var fails = false

    func setFailure(_ value: Bool) {
        fails = value
    }

    func fetch(_: URL) throws -> LinkMetadata {
        calls += 1
        if fails {
            throw URLError(.notConnectedToInternet)
        }
        return LinkMetadata(title: "A good read")
    }
}

private struct FailingStore: BookmarkStoring {
    func all() throws -> [Bookmark] {
        throw BookmarkError.storage("Test failure")
    }

    func save(url _: URL, note _: String,
              tags _: [String]) throws -> SaveResult
    {
        throw BookmarkError.storage("Test failure")
    }

    func update(id _: UUID, change _: BookmarkChange) throws {
        throw BookmarkError.storage("Test failure")
    }

    func delete(id _: UUID) throws {
        throw BookmarkError.storage("Test failure")
    }
}
