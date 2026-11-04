import Foundation
import SQLite3

public actor BookmarkStore: BookmarkStoring {
    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func all() throws -> [Bookmark] {
        try connection().bookmarks()
    }

    public func save(url: URL, note: String = "", tags: [String] = []) throws -> SaveResult {
        let canonicalURL = try BookmarkURL.parse(url.absoluteString)
        let database = try connection()
        return try database.transaction {
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
        try database.transaction {
            guard var bookmark = try database.bookmarks().first(where: { $0.id == id }) else {
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
            try database.write(bookmark)
        }
    }

    public func delete(id: UUID) throws {
        let database = try connection()
        try database.delete(id)
    }

    private func connection() throws -> SQLiteConnection {
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
}

/// Connections never cross suspension points. SQLite transactions protect app/extension writes across processes.
private final class SQLiteConnection {
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
            sqlite3_busy_timeout(handle, 3000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try transaction {
                let version = try schemaVersion()
                guard version <= 1 else { throw BookmarkError.unsupportedDatabase(version) }
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
            }
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
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

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        return statement
    }

    private func bind(_ text: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> BookmarkError {
        .storage(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database")
    }
}
