import Foundation
import OSLog
import SQLite3

public actor BookmarkStore: BookmarkStoring {
    private let databaseURL: URL
    public nonisolated let accountID: UUID?

    public init(databaseURL: URL, accountID: UUID? = nil) {
        self.databaseURL = databaseURL
        self.accountID = accountID
    }

    public static func activeAccountID(databaseURL: URL) throws -> UUID? {
        try open(databaseURL).activeAccountID()
    }

    public func all() throws -> [Bookmark] {
        let database = try connection()
        return try database.transaction { [accountID] in
            try Self.requireActiveAccount(database, expected: accountID)
            if let accountID {
                return try database.cloudRecords(owner: accountID).filter { !$0.isDeleted }.map(\.bookmark)
            }
            return try database.bookmarks()
        }
    }

    public func save(url: URL, note: String = "", tags: [String] = []) throws -> SaveResult {
        let canonicalURL = try BookmarkURL.parse(url.absoluteString)
        let database = try connection()
        return try database.transaction { [accountID] in
            try Self.requireActiveAccount(database, expected: accountID)
            if let accountID {
                let existing = try database.cloudRecords(owner: accountID).first { $0.bookmark.url == canonicalURL }
                if let existing, !existing.isDeleted {
                    return SaveResult(bookmark: existing.bookmark, inserted: false)
                }
                let bookmark = Bookmark(
                    id: existing?.bookmark.id ?? UUID(), url: canonicalURL, note: note, tags: tags,
                    createdAt: existing?.bookmark.createdAt ?? .now
                )
                try Self.enqueue(
                    bookmark,
                    version: existing?.version ?? 0,
                    deleted: false,
                    in: database,
                    owner: accountID
                )
                return SaveResult(bookmark: bookmark, inserted: true)
            }
            if let existing = try database.bookmarks().first(where: { $0.url == canonicalURL }) {
                return SaveResult(bookmark: existing, inserted: false)
            }
            let bookmark = Bookmark(url: canonicalURL, note: note, tags: tags)
            try database.write(bookmark)
            return SaveResult(bookmark: bookmark, inserted: true)
        }
    }

    public func update(id: UUID, change: BookmarkChange) throws {
        let database = try connection()
        try database.transaction { [accountID] in
            try Self.requireActiveAccount(database, expected: accountID)
            let cloudRecord = try accountID.flatMap { owner in
                try database.cloudRecords(owner: owner).first { $0.bookmark.id == id && !$0.isDeleted }
            }
            let saved = try accountID == nil ? database.bookmarks().first { $0.id == id } : cloudRecord?.bookmark
            guard var bookmark = saved else {
                throw BookmarkError.missingBookmark
            }
            switch change {
            case let .details(note, tags):
                bookmark.note = note
                bookmark.tags = Bookmark.normalizedTags(tags)
            case let .read(value):
                bookmark.isRead = value
            case let .favorite(value):
                bookmark.isFavorite = value
            case let .metadata(metadata):
                bookmark.title = metadata.title
                bookmark.imageURL = metadata.imageURL
                bookmark.metadataState = .ready
                bookmark.metadataMessage = nil
            case let .metadataFailed(message):
                bookmark.metadataState = .failed
                bookmark.metadataMessage = message
            case .retryMetadata:
                bookmark.metadataState = .pending
                bookmark.metadataMessage = nil
            }
            if let accountID {
                try Self.enqueue(
                    bookmark,
                    version: cloudRecord?.version ?? 0,
                    deleted: false,
                    in: database,
                    owner: accountID
                )
            } else {
                try database.write(bookmark)
            }
        }
    }

    public func delete(id: UUID) throws {
        let database = try connection()
        try database.transaction { [accountID] in
            try Self.requireActiveAccount(database, expected: accountID)
            if let accountID {
                guard let record = try database.cloudRecords(owner: accountID).first(where: { $0.bookmark.id == id })
                else {
                    throw BookmarkError.missingBookmark
                }
                try Self.enqueue(
                    record.bookmark,
                    version: record.version,
                    deleted: true,
                    in: database,
                    owner: accountID
                )
            } else {
                try database.delete(id)
            }
        }
    }

    private func connection() throws -> SQLiteConnection {
        try Self.open(databaseURL)
    }

    private static func open(_ databaseURL: URL) throws -> SQLiteConnection {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
        #endif
        return try SQLiteConnection(url: databaseURL)
    }

    public func activateAccount(_ id: UUID?) throws -> BookmarkStore {
        let database = try connection()
        try database.transaction { try database.setActiveAccount(id) }
        return BookmarkStore(databaseURL: databaseURL, accountID: id)
    }

    public func signOutAndRemoveAccountCache() throws -> BookmarkStore {
        let database = try connection()
        try database.transaction { [accountID] in
            try Self.requireActiveAccount(database, expected: accountID)
            if let accountID {
                try database.removeAccount(accountID)
            }
            try database.setActiveAccount(nil)
        }
        return BookmarkStore(databaseURL: databaseURL)
    }

    public func importGuestBookmarks() throws -> Int {
        let owner = try requireCloudAccount()
        let database = try connection()
        return try database.transaction {
            try Self.requireActiveAccount(database, expected: owner)
            let existingURLs = try Set(database.cloudRecords(owner: owner).map(\.bookmark.url))
            let guests = try database.bookmarks().filter { !existingURLs.contains($0.url) }
            for bookmark in guests {
                try Self.enqueue(bookmark, version: 0, deleted: false, in: database, owner: owner)
            }
            return guests.count
        }
    }

    public func pendingChanges() throws -> [PendingChange] {
        let owner = try requireCloudAccount()
        let database = try connection()
        return try database.transaction {
            try Self.requireActiveAccount(database, expected: owner)
            return try database.pending(owner: owner)
        }
    }

    public func conflicts() throws -> [SyncConflict] {
        let owner = try requireCloudAccount()
        let database = try connection()
        return try database.transaction {
            try Self.requireActiveAccount(database, expected: owner)
            let pending = try database.pending(owner: owner)
            let conflicts = try database.conflictRecords(owner: owner)
            return pending.compactMap { change in
                guard let conflict = conflicts.first(where: { $0.id == change.id }) else { return nil }
                return SyncConflict(local: change, remote: conflict.remote)
            }
        }
    }

    public func acknowledge(_ sent: PendingChange, result: MutationResult) throws {
        let owner = try requireCloudAccount()
        let database = try connection()
        try database.transaction {
            try Self.requireActiveAccount(database, expected: owner)
            guard let current = try database.pending(owner: owner).first(where: { $0.id == sent.id }) else { return }
            if let record = result.record, record.version <= 0 {
                throw SyncError.invalidResponse
            }
            if result.status == .conflict {
                if let record = result.record, record.version >= current.baseVersion,
                   record.isDeleted == current.isDeleted, record.bookmark.hasSameContent(as: current.bookmark)
                {
                    try database.writeCloud(record, owner: owner)
                    try database.removePending(current.id, owner: owner)
                    try database.removeConflict(current.id, owner: owner)
                    return
                }
                if current.operationID != sent.operationID,
                   (result.record?.version ?? 0) <= current.baseVersion
                {
                    return
                }
                try database.writeConflict(StoredConflict(id: sent.id, remote: result.record), owner: owner)
                return
            }
            guard let record = result.record, record.version > 0, record.bookmark.id == sent.id else {
                throw SyncError.invalidResponse
            }
            guard current.baseVersion <= record.version else { return }
            if current.operationID == sent.operationID {
                try database.writeCloud(record, owner: owner)
                try database.removePending(sent.id, owner: owner)
                try database.removeConflict(sent.id, owner: owner)
            } else {
                // Acknowledging an older request must never erase a newer edit or delete.
                let rebased = PendingChange(
                    operationID: current.operationID, bookmark: current.bookmark,
                    baseVersion: record.version, isDeleted: current.isDeleted
                )
                try database.writeCloud(
                    RemoteBookmark(bookmark: current.bookmark, version: record.version, isDeleted: current.isDeleted),
                    owner: owner
                )
                try database.writePending(rebased, owner: owner)
            }
        }
    }

    public func integrate(_ records: [RemoteBookmark]) throws {
        let owner = try requireCloudAccount()
        let database = try connection()
        try database.transaction {
            try Self.requireActiveAccount(database, expected: owner)
            for record in records {
                guard record.version > 0 else { throw SyncError.invalidResponse }
                try Self.validateCloudBookmark(record.bookmark)
                let pending = try database.pending(owner: owner).first {
                    $0.id == record.bookmark.id || $0.bookmark.url == record.bookmark.url
                }
                if let pending {
                    if record.version >= pending.baseVersion, record.isDeleted == pending.isDeleted,
                       record.bookmark.hasSameContent(as: pending.bookmark)
                    {
                        try database.writeCloud(record, owner: owner)
                        try database.removePending(pending.id, owner: owner)
                        try database.removeConflict(pending.id, owner: owner)
                        continue
                    }
                    if pending.id != record.bookmark.id || record.version > pending.baseVersion {
                        try database.writeConflict(StoredConflict(id: pending.id, remote: record), owner: owner)
                    }
                    continue
                }
                let existing = try database.cloudRecords(owner: owner).first {
                    $0.bookmark.id == record.bookmark.id || $0.bookmark.url == record.bookmark.url
                }
                if let existing, existing.bookmark.id == record.bookmark.id, existing.version > record.version {
                    continue
                }
                if let existing, existing.bookmark.id != record.bookmark.id {
                    try database.removeCloud(existing.bookmark.id, owner: owner)
                }
                try database.writeCloud(record, owner: owner)
            }
        }
    }

    public func resolveConflict(
        _ id: UUID, using resolution: ConflictResolution, expectedRemoteVersion: Int64? = nil
    ) throws {
        let owner = try requireCloudAccount()
        let database = try connection()
        try database.transaction {
            try Self.requireActiveAccount(database, expected: owner)
            guard let pending = try database.pending(owner: owner).first(where: { $0.id == id }),
                  let conflict = try database.conflictRecords(owner: owner).first(where: { $0.id == id })
            else {
                throw BookmarkError.missingBookmark
            }
            if let expectedRemoteVersion, expectedRemoteVersion != (conflict.remote?.version ?? 0) {
                throw SyncError.conflictChanged
            }
            try database.removePending(id, owner: owner)
            try database.removeConflict(id, owner: owner)
            try database.removeCloud(id, owner: owner)
            switch resolution {
            case .useCloud:
                if let remote = conflict.remote {
                    try database.writeCloud(remote, owner: owner)
                }
            case .keepDevice:
                var bookmark = pending.bookmark
                if let remote = conflict.remote, remote.bookmark.id != id {
                    bookmark = bookmark.replacingIdentity(with: remote.bookmark)
                }
                try Self.enqueue(
                    bookmark, version: conflict.remote?.version ?? 0, deleted: pending.isDeleted,
                    in: database, owner: owner
                )
            }
        }
    }

    private static func enqueue(
        _ bookmark: Bookmark, version: Int64, deleted: Bool, in database: SQLiteConnection, owner: UUID
    ) throws {
        try validateCloudBookmark(bookmark)
        try database.writeCloud(RemoteBookmark(bookmark: bookmark, version: version, isDeleted: deleted), owner: owner)
        try database.writePending(
            PendingChange(bookmark: bookmark, baseVersion: version, isDeleted: deleted),
            owner: owner
        )
    }

    private static func requireActiveAccount(_ database: SQLiteConnection, expected: UUID?) throws {
        guard try database.activeAccountID() == expected else { throw SyncError.accountChanged }
    }

    private func requireCloudAccount() throws -> UUID {
        guard let accountID else { throw SyncError.accountRequired }
        return accountID
    }

    private static func validateCloudBookmark(_ bookmark: Bookmark) throws {
        _ = try BookmarkURL.parse(bookmark.url.absoluteString)
        guard bookmark.note.utf8.count <= 20000, bookmark.title.utf8.count <= 1000,
              bookmark.url.absoluteString.utf8.count <= 8192, bookmark.tags.count <= 32,
              bookmark.tags.allSatisfy({ $0.utf8.count <= 80 })
        else {
            throw SyncError
                .invalidBookmark("This bookmark is too large to sync. Use a note under 20 KB and up to 32 short tags.")
        }
    }
}

/// Connections never cross suspension points. SQLite transactions protect app/extension writes across processes.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(handle)
            handle = nil
            throw error
        }
        do {
            try enableWriteAheadLogging()
            sqlite3_busy_timeout(handle, 3000)
            try execute("PRAGMA synchronous=FULL")
            try transaction {
                let version = try schemaVersion()
                guard version <= 2 else { throw BookmarkError.unsupportedDatabase(version) }
                if version == 0 {
                    try execute("""
                    CREATE TABLE IF NOT EXISTS bookmarks (
                        id TEXT PRIMARY KEY NOT NULL,
                        url TEXT UNIQUE NOT NULL,
                        created_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    )
                    """)
                    try execute("PRAGMA user_version=1")
                }
                if version < 2 {
                    try execute("""
                    CREATE TABLE active_account (singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT);
                    INSERT INTO active_account(singleton, account_id) VALUES (1, NULL);
                    CREATE TABLE cloud_bookmarks (
                        owner_id TEXT NOT NULL, id TEXT NOT NULL, url TEXT NOT NULL, created_at REAL NOT NULL,
                        payload BLOB NOT NULL, PRIMARY KEY(owner_id, id), UNIQUE(owner_id, url)
                    );
                    CREATE TABLE pending_changes (
                        owner_id TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(owner_id, id)
                    );
                    CREATE TABLE sync_conflicts (
                        owner_id TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(owner_id, id)
                    );
                    PRAGMA user_version=2;
                    """)
                }
            }
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    private func enableWriteAheadLogging() throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var reportedContention = false
        while true {
            let result = sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil)
            if result == SQLITE_OK {
                return
            }
            guard result == SQLITE_BUSY, ContinuousClock.now < deadline else {
                throw failure(operation: "PRAGMA journal_mode=WAL")
            }
            // SQLite can bypass its busy handler when concurrent connections promote the journal mode.
            if !reportedContention {
                Logger(subsystem: "com.avinashrajavarapu.pocketqueue", category: "storage")
                    .debug("Waiting for a concurrent database initialization")
                reportedContention = true
            }
            sqlite3_sleep(10)
        }
    }

    /// Keep the connection and callback on the caller's executor without making SQLiteConnection Sendable.
    func transaction<T>(isolation _: isolated (any Actor)? = #isolation, _ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            let original = error
            do {
                try execute("ROLLBACK")
            } catch {
                throw BookmarkError.storage("Transaction and rollback failed: \(error)")
            }
            throw original
        }
    }

    func bookmarks() throws -> [Bookmark] {
        let statement = try prepare("SELECT payload FROM bookmarks ORDER BY created_at DESC, id ASC")
        defer { sqlite3_finalize(statement) }
        var result: [Bookmark] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            try result.append(JSONDecoder().decode(Bookmark.self, from: data))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw failure() }
        return result
    }

    func write(_ bookmark: Bookmark) throws {
        let statement = try prepare("""
        INSERT INTO bookmarks (id, url, created_at, payload) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET payload=excluded.payload
        """)
        defer { sqlite3_finalize(statement) }
        try bind(bookmark.id.uuidString, at: 1, to: statement)
        try bind(bookmark.url.absoluteString, at: 2, to: statement)
        guard sqlite3_bind_double(statement, 3, bookmark.createdAt.timeIntervalSince1970) == SQLITE_OK else {
            throw failure()
        }
        let data = try JSONEncoder().encode(bookmark)
        let code = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient)
        }
        guard code == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func delete(_ id: UUID) throws {
        let statement = try prepare("DELETE FROM bookmarks WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(statement, 0))
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw failure(operation: sql)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        return statement
    }

    func bind(_ text: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw failure() }
    }

    func failure(operation: String = "SQLite operation") -> BookmarkError {
        let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
        return .storage("\(operation): \(detail)")
    }
}
