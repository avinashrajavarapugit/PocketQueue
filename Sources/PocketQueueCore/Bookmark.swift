import Foundation

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public enum MetadataState: String, Codable, Sendable {
        case pending, ready, failed
    }

    public let id: UUID
    public let url: URL
    public let createdAt: Date
    public var title: String
    public var note: String
    public var tags: [String]
    public var isRead: Bool
    public var isFavorite: Bool
    public var metadataState: MetadataState
    public var metadataMessage: String?
    public var imageURL: URL?

    public var domain: String {
        url.host() ?? url.absoluteString
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String = "",
        note: String = "",
        tags: [String] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
        self.title = title.isEmpty ? (url.host() ?? url.absoluteString) : title
        self.note = note
        self.tags = Self.normalizedTags(tags)
        isRead = false
        isFavorite = false
        metadataState = .pending
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
    }

    public func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let content = ([title, url.absoluteString, note] + tags).joined(separator: " ")
        return terms.allSatisfy { content.localizedStandardContains($0) }
    }
}

public enum BookmarkError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case missingBookmark
    case storage(String)
    case unsupportedDatabase(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid http or https link without a username or password."
        case .missingBookmark:
            "This bookmark was removed. Refresh your library to continue."
        case .storage:
            "Your library could not be read or saved. Please try again; existing data has not been reset."
        case .unsupportedDatabase:
            "This library was created by a newer version of PocketQueue. Update the app to open it."
        }
    }
}

public enum BookmarkURL {
    public static func parse(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else {
            throw BookmarkError.invalidURL
        }
        let candidate = URLComponents(string: trimmed)
        let value = candidate?.scheme == nil ? "https://\(trimmed)" : trimmed
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else {
            throw BookmarkError.invalidURL
        }
        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        guard let url = components.url else { throw BookmarkError.invalidURL }
        return url
    }
}

public struct SaveResult: Sendable {
    public let bookmark: Bookmark
    public let inserted: Bool
}

public enum BookmarkChange: Sendable {
    case details(note: String, tags: [String])
    case read(Bool)
    case favorite(Bool)
    case metadata(LinkMetadata)
    case metadataFailed(String)
    case retryMetadata
}

public protocol BookmarkStoring: Sendable {
    func all() async throws -> [Bookmark]
    func save(url: URL, note: String, tags: [String]) async throws -> SaveResult
    func update(id: UUID, change: BookmarkChange) async throws
    func delete(id: UUID) async throws
}
