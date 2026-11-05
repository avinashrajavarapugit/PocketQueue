import Foundation
import SQLite3

struct StoredConflict: Codable {
    let id: UUID
    let remote: RemoteBookmark?
}

extension Bookmark {
    func hasSameContent(as other: Bookmark) -> Bool {
        id == other.id && url == other.url && title == other.title && note == other.note &&
            tags == other.tags && isRead == other.isRead && isFavorite == other.isFavorite &&
            metadataState == other.metadataState && metadataMessage == other.metadataMessage && imageURL == other
            .imageURL
    }

    func replacingIdentity(with remote: Bookmark) -> Bookmark {
        var result = Bookmark(
            id: remote.id,
            url: remote.url,
            title: title,
            note: note,
            tags: tags,
            createdAt: remote.createdAt
        )
        result.isRead = isRead
        result.isFavorite = isFavorite
        result.metadataState = metadataState
        result.metadataMessage = metadataMessage
        result.imageURL = imageURL
        return result
    }
}

extension SQLiteConnection {
    func activeAccountID() throws -> UUID? {
        let statement = try prepare("SELECT account_id FROM active_account WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL {
            return nil
        }
        guard let text = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: text)) else { throw failure() }
        return id
    }

    func setActiveAccount(_ id: UUID?) throws {
        let statement = try prepare("UPDATE active_account SET account_id=? WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        if let id {
            try bind(id.uuidString, at: 1, to: statement)
        } else {
            guard sqlite3_bind_null(statement, 1) == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func cloudRecords(owner: UUID) throws -> [RemoteBookmark] {
        try readPayloads(
            "SELECT payload FROM cloud_bookmarks WHERE owner_id=? ORDER BY created_at DESC, id ASC", owner: owner
        )
    }

    func pending(owner: UUID) throws -> [PendingChange] {
        try readPayloads("SELECT payload FROM pending_changes WHERE owner_id=? ORDER BY id", owner: owner)
    }

    func conflictRecords(owner: UUID) throws -> [StoredConflict] {
        try readPayloads("SELECT payload FROM sync_conflicts WHERE owner_id=? ORDER BY id", owner: owner)
    }

    func writeCloud(_ record: RemoteBookmark, owner: UUID) throws {
        let statement = try prepare("""
        INSERT INTO cloud_bookmarks(owner_id,id,url,created_at,payload) VALUES(?,?,?,?,?)
        ON CONFLICT(owner_id,id) DO UPDATE SET url=excluded.url,created_at=excluded.created_at,payload=excluded.payload
        """)
        defer { sqlite3_finalize(statement) }
        try bind(owner.uuidString, at: 1, to: statement)
        try bind(record.bookmark.id.uuidString, at: 2, to: statement)
        try bind(record.bookmark.url.absoluteString, at: 3, to: statement)
        guard sqlite3_bind_double(statement, 4, record.bookmark.createdAt.timeIntervalSince1970) == SQLITE_OK else {
            throw failure()
        }
        try bindPayload(record, at: 5, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func writePending(_ change: PendingChange, owner: UUID) throws {
        try writePayload(change, id: change.id, owner: owner, table: "pending_changes")
    }

    func writeConflict(_ conflict: StoredConflict, owner: UUID) throws {
        try writePayload(conflict, id: conflict.id, owner: owner, table: "sync_conflicts")
    }

    func removePending(_ id: UUID, owner: UUID) throws {
        try remove(id, owner: owner, table: "pending_changes")
    }

    func removeConflict(_ id: UUID, owner: UUID) throws {
        try remove(id, owner: owner, table: "sync_conflicts")
    }

    func removeCloud(_ id: UUID, owner: UUID) throws {
        try remove(id, owner: owner, table: "cloud_bookmarks")
    }

    func removeAccount(_ owner: UUID) throws {
        for table in ["cloud_bookmarks", "pending_changes", "sync_conflicts"] {
            let statement = try prepare("DELETE FROM \(table) WHERE owner_id=?")
            defer { sqlite3_finalize(statement) }
            try bind(owner.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }

    private func readPayloads<T: Decodable>(_ sql: String, owner: UUID) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(owner.uuidString, at: 1, to: statement)
        var results: [T] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            try results.append(JSONDecoder().decode(T.self, from: data))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw failure() }
        return results
    }

    private func writePayload(_ value: some Encodable, id: UUID, owner: UUID, table: String) throws {
        let statement = try prepare("""
        INSERT INTO \(table)(owner_id,id,payload) VALUES(?,?,?)
        ON CONFLICT(owner_id,id) DO UPDATE SET payload=excluded.payload
        """)
        defer { sqlite3_finalize(statement) }
        try bind(owner.uuidString, at: 1, to: statement)
        try bind(id.uuidString, at: 2, to: statement)
        try bindPayload(value, at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func remove(_ id: UUID, owner: UUID, table: String) throws {
        let statement = try prepare("DELETE FROM \(table) WHERE owner_id=? AND id=?")
        defer { sqlite3_finalize(statement) }
        try bind(owner.uuidString, at: 1, to: statement)
        try bind(id.uuidString, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func bindPayload(_ value: some Encodable, at index: Int32, to statement: OpaquePointer) throws {
        let data = try JSONEncoder().encode(value)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code = data
            .withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        guard code == SQLITE_OK else { throw failure() }
    }
}
