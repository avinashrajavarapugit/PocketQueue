import Foundation

public struct GraphQLBookmarkClient: CloudBookmarkTransport {
    private let configuration: BackendConfiguration
    private let authentication: any CloudAuthenticating
    private let accountID: UUID
    private let session: URLSession

    public init(
        configuration: BackendConfiguration,
        authentication: any CloudAuthenticating,
        accountID: UUID,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.configuration = configuration
        self.authentication = authentication
        self.accountID = accountID
        self.session = session
    }

    public func fetchPage(after cursor: String?) async throws -> BookmarkPage {
        let response: CollectionResponse = try await request(
            query: """
            query Bookmarks($after: Cursor) {
              bookmarksCollection(first: 50, after: $after, orderBy: [{id: AscNullsLast}]) {
                edges { node {
                  ownerId id url title note tags isRead isFavorite createdAt
                  metadataState metadataMessage imageUrl revision deleted
                } }
                pageInfo { endCursor hasNextPage }
              }
            }
            """,
            variables: PageVariables(after: cursor)
        )
        let collection = response.bookmarksCollection
        let records = try collection.edges.map { edge in
            guard edge.node.ownerId == accountID else { throw SyncError.accountChanged }
            return try edge.node.record()
        }
        return BookmarkPage(
            records: records, endCursor: collection.pageInfo.endCursor,
            hasNextPage: collection.pageInfo.hasNextPage
        )
    }

    public func apply(_ change: PendingChange) async throws -> MutationResult {
        let encodedBookmark = try SyncCoding.encoder().encode(change.bookmark)
        guard let bookmark = String(data: encodedBookmark, encoding: .utf8) else { throw SyncError.invalidResponse }
        let response: ApplyResponse = try await request(
            query: """
            mutation ApplyBookmark($operationId: UUID!, $expectedVersion: BigInt!, $bookmark: JSON!, $isDeleted: Boolean!) {
              applyBookmarkChange(operationId: $operationId, expectedVersion: $expectedVersion,
                                  bookmark: $bookmark, isDeleted: $isDeleted)
            }
            """,
            variables: ApplyVariables(
                operationId: change.operationID, expectedVersion: String(change.baseVersion),
                bookmark: bookmark, isDeleted: change.isDeleted
            )
        )
        let result = try SyncCoding.decoder().decode(
            MutationResult.self, from: Data(response.applyBookmarkChange.utf8)
        )
        if result.status == .applied, result.record == nil {
            throw SyncError.invalidResponse
        }
        return result
    }

    private func request<Result: Decodable>(
        query: String, variables: some Encodable
    ) async throws -> Result {
        guard try await authentication.currentUser()?.id == accountID else { throw SyncError.accountChanged }
        let token = try await authentication.accessToken()
        try Task.checkCancellation()
        guard try await authentication.currentUser()?.id == accountID else { throw SyncError.accountChanged }
        var request = URLRequest(url: configuration.url.appending(path: "graphql/v1"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        guard (200 ... 299).contains(response.statusCode) else { throw SyncError.httpStatus(response.statusCode) }
        guard data.count <= 4 * 1024 * 1024 else { throw SyncError.invalidResponse }
        let envelope = try JSONDecoder().decode(GraphQLResponse<Result>.self, from: data)
        if let errors = envelope.errors, !errors.isEmpty {
            throw SyncError.graphQL(String(errors.map(\.message).joined(separator: "; ").prefix(500)))
        }
        guard let result = envelope.data else { throw SyncError.invalidResponse }
        return result
    }
}

private struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables
}

private struct GraphQLResponse<Result: Decodable>: Decodable {
    struct ServerError: Decodable {
        let message: String
    }

    let data: Result?
    let errors: [ServerError]?

    private enum CodingKeys: String, CodingKey { case data, errors }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errors = try container.decodeIfPresent([ServerError].self, forKey: .errors)
        data = errors?.isEmpty == false ? nil : try container.decodeIfPresent(Result.self, forKey: .data)
    }
}

private struct PageVariables: Encodable {
    let after: String?
}

private struct ApplyVariables: Encodable {
    let operationId: UUID
    let expectedVersion: String
    let bookmark: String
    let isDeleted: Bool
}

private struct ApplyResponse: Decodable {
    let applyBookmarkChange: String
}

private struct CollectionResponse: Decodable {
    let bookmarksCollection: BookmarkCollection
}

private struct BookmarkCollection: Decodable {
    struct Edge: Decodable {
        let node: BookmarkNode
    }

    struct PageInfo: Decodable {
        let endCursor: String?
        let hasNextPage: Bool
    }

    let edges: [Edge]
    let pageInfo: PageInfo
}

private struct BookmarkNode: Decodable {
    let ownerId: UUID
    let id: UUID
    let url: URL
    let title: String
    let note: String
    let tags: [String]
    let isRead: Bool
    let isFavorite: Bool
    let createdAt: String
    let metadataState: Bookmark.MetadataState
    let metadataMessage: String?
    let imageUrl: URL?
    let revision: GraphQLVersion
    let deleted: Bool

    func record() throws -> RemoteBookmark {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        guard let date = fractional.date(from: createdAt) ?? ordinary.date(from: createdAt), revision.value > 0 else {
            throw SyncError.invalidResponse
        }
        var bookmark = Bookmark(id: id, url: url, title: title, note: note, tags: tags, createdAt: date)
        bookmark.isRead = isRead
        bookmark.isFavorite = isFavorite
        bookmark.metadataState = metadataState
        bookmark.metadataMessage = metadataMessage
        bookmark.imageURL = imageUrl
        return RemoteBookmark(bookmark: bookmark, version: revision.value, isDeleted: deleted)
    }
}

private struct GraphQLVersion: Decodable {
    let value: Int64

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard let value = Int64(text) else { throw SyncError.invalidResponse }
            self.value = value
        } else {
            value = try container.decode(Int64.self)
        }
    }
}
