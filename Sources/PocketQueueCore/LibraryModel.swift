import Foundation
import Observation
import OSLog

public enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case unread = "Queue"
    case favorites = "Favorites"
    case read = "Read"
    case all = "All"

    public var id: String {
        rawValue
    }
}

@MainActor
@Observable
public final class LibraryModel {
    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var visibleBookmarks: [Bookmark] = []
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var refreshID = 0
    public var errorMessage: String?
    public var notice: String?
    public var searchText = "" {
        didSet { rebuildVisibleBookmarks() }
    }

    public var filter: LibraryFilter = .unread {
        didSet { rebuildVisibleBookmarks() }
    }

    private let store: any BookmarkStoring
    private let metadata: any MetadataFetching
    private let didChange: @MainActor @Sendable () -> Void
    private let logger = Logger(subsystem: "com.avinashrajavarapu.pocketqueue", category: "library")
    private var loadGeneration = 0

    public init(
        store: any BookmarkStoring,
        metadata: any MetadataFetching,
        didChange: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.store = store
        self.metadata = metadata
        self.didChange = didChange
    }

    public func requestRefresh() {
        refreshID += 1
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        do {
            let items = try await store.all()
            guard generation == loadGeneration else { return }
            bookmarks = items
            rebuildVisibleBookmarks()
        } catch {
            guard generation == loadGeneration else { return }
            report(error, operation: "load")
        }
        if generation == loadGeneration {
            isLoading = false
        }
    }

    @discardableResult
    public func save(_ input: String, note: String = "", tags: [String] = []) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let url = try BookmarkURL.parse(input)
            let result = try await store.save(url: url, note: note, tags: tags)
            notice = result.inserted ? "Saved on this device." : "This link is already saved."
            await load()
            didChange()
            requestRefresh()
            return true
        } catch {
            report(error, operation: "save")
            return false
        }
    }

    @discardableResult
    public func update(_ id: UUID, change: BookmarkChange) async -> Bool {
        do {
            try await store.update(id: id, change: change)
            await load()
            didChange()
            if case .retryMetadata = change {
                requestRefresh()
            }
            return true
        } catch {
            report(error, operation: "update")
            return false
        }
    }

    @discardableResult
    public func delete(_ id: UUID) async -> Bool {
        do {
            try await store.delete(id: id)
            await load()
            didChange()
            return true
        } catch {
            report(error, operation: "delete")
            return false
        }
    }

    public func refresh() async {
        await load()
        guard !Task.isCancelled else { return }
        let pending = bookmarks.filter { $0.metadataState == .pending }
        let store = store
        let metadata = metadata
        await withTaskGroup(of: String?.self) { group in
            var iterator = pending.makeIterator()
            func enqueue(_ bookmark: Bookmark) {
                group.addTask {
                    do {
                        let value = try await metadata.fetch(bookmark.url)
                        try Task.checkCancellation()
                        try await store.update(id: bookmark.id, change: .metadata(value))
                    } catch is CancellationError {
                        return nil
                    } catch BookmarkError.missingBookmark {
                        return nil
                    } catch {
                        if Task.isCancelled {
                            return nil
                        }
                        do {
                            try await store.update(
                                id: bookmark.id, change: .metadataFailed(error.localizedDescription)
                            )
                        } catch BookmarkError.missingBookmark {
                            return nil
                        } catch {
                            return error.localizedDescription
                        }
                    }
                    return nil
                }
            }
            for _ in 0 ..< 3 {
                if let bookmark = iterator.next() {
                    enqueue(bookmark)
                }
            }
            for await failure in group {
                if let failure {
                    logger.error("Could not persist metadata state")
                    errorMessage = failure
                }
                if !Task.isCancelled {
                    await load()
                    didChange()
                    if let bookmark = iterator.next() {
                        enqueue(bookmark)
                    }
                }
            }
        }
    }

    private func rebuildVisibleBookmarks() {
        visibleBookmarks = bookmarks.filter { bookmark in
            let included: Bool = switch filter {
            case .unread: !bookmark.isRead
            case .favorites: bookmark.isFavorite
            case .read: bookmark.isRead
            case .all: true
            }
            return included && bookmark.matches(searchText)
        }
    }

    private func report(_ error: Error, operation: String) {
        logger.error("Library operation failed: \(operation, privacy: .public)")
        errorMessage = error.localizedDescription
    }
}
