import Foundation

public struct RemoteBookmark: Codable, Equatable, Sendable {
    public let bookmark: Bookmark
    public let version: Int64
    public let isDeleted: Bool

    public init(bookmark: Bookmark, version: Int64, isDeleted: Bool = false) {
        self.bookmark = bookmark
        self.version = version
        self.isDeleted = isDeleted
    }
}

public struct PendingChange: Codable, Equatable, Sendable, Identifiable {
    public let operationID: UUID
    public let bookmark: Bookmark
    public let baseVersion: Int64
    public let isDeleted: Bool
    public var id: UUID {
        bookmark.id
    }

    public init(operationID: UUID = UUID(), bookmark: Bookmark, baseVersion: Int64, isDeleted: Bool = false) {
        self.operationID = operationID
        self.bookmark = bookmark
        self.baseVersion = baseVersion
        self.isDeleted = isDeleted
    }
}

public struct SyncConflict: Codable, Equatable, Sendable, Identifiable {
    public let local: PendingChange
    public let remote: RemoteBookmark?
    public var id: UUID {
        local.id
    }
}

public struct MutationResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case applied, conflict
    }

    public let status: Status
    public let record: RemoteBookmark?

    public init(status: Status, record: RemoteBookmark?) {
        self.status = status
        self.record = record
    }
}

public struct BookmarkPage: Sendable {
    public let records: [RemoteBookmark]
    public let endCursor: String?
    public let hasNextPage: Bool

    public init(records: [RemoteBookmark], endCursor: String? = nil, hasNextPage: Bool = false) {
        self.records = records
        self.endCursor = endCursor
        self.hasNextPage = hasNextPage
    }
}

public struct SyncSummary: Equatable, Sendable {
    public let pendingCount: Int
    public let conflictCount: Int
}

public enum ConflictResolution: Sendable {
    case keepDevice, useCloud
}

public enum SyncError: LocalizedError, Equatable, Sendable {
    case accountChanged
    case accountRequired
    case inProgress
    case invalidResponse
    case httpStatus(Int)
    case graphQL(String)
    case invalidBookmark(String)
    case conflictChanged

    public var errorDescription: String? {
        switch self {
        case .accountChanged: "The active account changed. Reopen this screen before saving."
        case .accountRequired: "Sign in to sync your library."
        case .inProgress: "A sync is already running."
        case .invalidResponse: "The server returned an invalid sync response. Your local changes are still queued."
        case .httpStatus(401), .httpStatus(403): "Your session cannot access the server. Sign in again to resume syncing."
        case let .httpStatus(code): "Sync could not reach the server (HTTP \(code)). Your changes are still saved locally."
        case let .graphQL(message): "Sync could not complete: \(message)"
        case let .invalidBookmark(message): message
        case .conflictChanged: "The cloud version changed again. Review the refreshed conflict before choosing a version."
        }
    }
}

public protocol CloudBookmarkTransport: Sendable {
    func fetchPage(after cursor: String?) async throws -> BookmarkPage
    func apply(_ change: PendingChange) async throws -> MutationResult
}

public enum SyncCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
