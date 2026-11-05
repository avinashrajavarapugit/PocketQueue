import Foundation

public actor BookmarkSyncEngine {
    private let store: BookmarkStore
    private let remote: any CloudBookmarkTransport
    private var running = false

    public init(store: BookmarkStore, remote: any CloudBookmarkTransport) {
        self.store = store
        self.remote = remote
    }

    public func synchronize() async throws -> SyncSummary {
        guard !running else { throw SyncError.inProgress }
        running = true
        defer { running = false }
        let conflicts = try await Set(store.conflicts().map(\.id))
        for change in try await store.pendingChanges() where !conflicts.contains(change.id) {
            try Task.checkCancellation()
            let result = try await remote.apply(change)
            try Task.checkCancellation()
            try await store.acknowledge(change, result: result)
        }
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            try Task.checkCancellation()
            let page = try await remote.fetchPage(after: cursor)
            try Task.checkCancellation()
            try await store.integrate(page.records)
            if !page.hasNextPage {
                break
            }
            guard let next = page.endCursor, !page.records.isEmpty, seenCursors.insert(next).inserted else {
                throw SyncError.invalidResponse
            }
            cursor = next
        } while true
        return try await SyncSummary(pendingCount: store.pendingChanges().count, conflictCount: store.conflicts().count)
    }
}
