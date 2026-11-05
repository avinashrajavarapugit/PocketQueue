import Foundation
@testable import PocketQueueCore
import Testing

struct GraphQLClientTests {
    @Test func decodesTypedQueryFieldsAndBigIntRevision() async throws {
        let page = try await client("good.example").fetchPage(after: nil)
        #expect(page.records.count == 1)
        #expect(page.records.first?.version == 7)
        #expect(page.records.first?.bookmark.title == "Cloud article")
        #expect(page.records.first?.bookmark.note == "Saved remotely")
        #expect(page.records.first?.bookmark.isFavorite == true)
        #expect(page.endCursor == "next")
        #expect(!page.hasNextPage)
    }

    @Test func serializesMutationJSONScalarAndDecodesItsReceipt() async throws {
        let bookmark = try Bookmark(
            url: BookmarkURL.parse("example.com/mutation"), note: "Quotes \" stay safe",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.125)
        )
        let pending = PendingChange(bookmark: bookmark, baseVersion: 4)
        let result = try await client("good.example").apply(pending)
        #expect(result.status == .applied)
        #expect(result.record?.version == 5)
        #expect(result.record?.bookmark == bookmark)
    }

    @Test func rejectsPartialGraphQLErrorsBeforeDecodingPartialData() async throws {
        await #expect(throws: SyncError.graphQL("Permission denied")) {
            try await client("partial.example").fetchPage(after: nil)
        }
    }

    @Test func distinguishesHTTPAuthFailureAndInvalidData() async throws {
        await #expect(throws: SyncError.httpStatus(401)) {
            try await client("unauthorized.example").fetchPage(after: nil)
        }
        await #expect(throws: SyncError.invalidResponse) {
            try await client("empty.example").fetchPage(after: nil)
        }
    }

    @Test func validatesReturnedAccountIdentity() async throws {
        await #expect(throws: SyncError.accountChanged) {
            try await client("wrong-owner.example").fetchPage(after: nil)
        }
    }

    private func client(_ host: String) throws -> GraphQLBookmarkClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphQLFixtureProtocol.self]
        return try GraphQLBookmarkClient(
            configuration: BackendConfiguration(
                url: BookmarkURL.parse("https://\(host)"), publishableKey: "sb_publishable_test_fixture"
            ),
            authentication: GraphQLAuthenticationFixture(),
            accountID: GraphQLFixtureProtocol.owner,
            session: URLSession(configuration: configuration)
        )
    }
}

private struct GraphQLAuthenticationFixture: CloudAuthenticating {
    func currentUser() -> CloudUser? {
        CloudUser(id: GraphQLFixtureProtocol.owner, email: "test@example.com")
    }

    func accessToken() -> String {
        "fixture-token"
    }

    func signIn(email _: String, password _: String) throws -> CloudUser {
        throw SyncError.accountRequired
    }

    func signUp(email _: String, password _: String) throws -> SignUpOutcome {
        throw SyncError.accountRequired
    }

    func signOut() -> SignOutOutcome {
        .complete
    }

    func handleCallback(_: URL) throws -> AuthCallbackOutcome {
        throw SyncError.accountRequired
    }

    func sendPasswordReset(email _: String) throws {
        throw SyncError.accountRequired
    }

    func updatePassword(_: String) throws {
        throw SyncError.accountRequired
    }

    func deleteAccount() throws {
        throw SyncError.accountRequired
    }
}

private class GraphQLFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let owner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasSuffix(".example") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let url = try #require(request.url)
            let status = url.host() == "unauthorized.example" ? 401 : 200
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            let body: Data = if url.host() == "partial.example" {
                Data(#"{"data":{"bookmarksCollection":null},"errors":[{"message":"Permission denied"}]}"#.utf8)
            } else if url.host() == "empty.example" {
                Data(#"{"data":null}"#.utf8)
            } else {
                try successfulResponse()
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func successfulResponse() throws -> Data {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                bytes.append(buffer, count: count)
            }
            data = bytes
        } else {
            throw URLError(.badServerResponse)
        }
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try #require(envelope["query"] as? String)
        if query.contains("mutation ApplyBookmark") {
            let variables = try #require(envelope["variables"] as? [String: Any])
            let json = try #require(variables["bookmark"] as? String)
            let bookmark = try SyncCoding.decoder().decode(Bookmark.self, from: Data(json.utf8))
            let baseText = try #require(variables["expectedVersion"] as? String)
            let base = try #require(Int64(baseText))
            let result = MutationResult(status: .applied, record: .init(bookmark: bookmark, version: base + 1))
            let resultText = try #require(String(data: SyncCoding.encoder().encode(result), encoding: .utf8))
            return try JSONSerialization.data(withJSONObject: ["data": ["applyBookmarkChange": resultText]])
        }
        let owner = request.url?.host() == "wrong-owner.example" ? UUID() : Self.owner
        return try JSONSerialization.data(withJSONObject: [
            "data": [
                "bookmarksCollection": [
                    "edges": [["node": [
                        "ownerId": owner.uuidString, "id": UUID().uuidString, "url": "https://example.com/cloud",
                        "title": "Cloud article", "note": "Saved remotely", "tags": ["swift"],
                        "isRead": false, "isFavorite": true, "createdAt": "2026-11-05T10:20:30.123456+00:00",
                        "metadataState": "ready", "metadataMessage": NSNull(), "imageUrl": NSNull(),
                        "revision": "7", "deleted": false,
                    ]]],
                    "pageInfo": ["endCursor": "next", "hasNextPage": false],
                ],
            ],
        ])
    }
}
