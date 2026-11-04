import Foundation
@testable import PocketQueueCore
import Testing

struct MetadataTests {
    @Test func extractsOpenGraphInEitherAttributeOrder() throws {
        let html = """
        <title>Fallback</title>
        <meta content='Swift &amp; Actors' property='og:title'>
        <meta property="og:image" content="/image.png">
        """
        let metadata = try MetadataParser.parse(html, baseURL: BookmarkURL.parse("example.com/article"))
        #expect(metadata.title == "Swift & Actors")
        #expect(metadata.imageURL?.absoluteString == "https://example.com/image.png")
    }

    @Test func fallsBackToTitleAndRejectsUnsafeImages() throws {
        let html = "<TITLE>  Hello\n world </TITLE><meta property='og:image' content='http://example.com/a.png'>"
        let metadata = try MetadataParser.parse(html, baseURL: BookmarkURL.parse("example.com"))
        #expect(metadata.title == "Hello world")
        #expect(metadata.imageURL == nil)
    }

    @Test func missingTitleIsAnExplicitFailure() throws {
        #expect(throws: MetadataError.noTitle) {
            try MetadataParser.parse("<html></html>", baseURL: BookmarkURL.parse("example.com"))
        }
    }

    @Test func networkClientValidatesStatusMIMEAndResponseSize() async throws {
        let client = makeClient()
        let metadata = try await client.fetch(BookmarkURL.parse("https://fixture.example/ok"))
        #expect(metadata.title == "Fixture article")
        await #expect(throws: MetadataError.httpStatus(429)) {
            try await client.fetch(BookmarkURL.parse("https://fixture.example/rate-limit"))
        }
        await #expect(throws: MetadataError.unsupportedContent) {
            try await client.fetch(BookmarkURL.parse("https://fixture.example/json"))
        }
        await #expect(throws: MetadataError.tooLarge) {
            try await client.fetch(BookmarkURL.parse("https://fixture.example/large"))
        }
        await #expect(throws: MetadataError.insecureURL) {
            try await client.fetch(BookmarkURL.parse("http://fixture.example/ok"))
        }
    }

    @Test func cancellationDoesNotReturnSuccess() async throws {
        let client = makeClient()
        let task = Task {
            try Task.checkCancellation()
            return try await client.fetch(BookmarkURL.parse("https://fixture.example/ok"))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled request returned success")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    private func makeClient() -> MetadataClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return MetadataClient(session: URLSession(configuration: configuration))
    }
}

class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let status = url.path == "/rate-limit" ? 429 : 200
        let contentType = url.path == "/json" ? "application/json" : "text/html"
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType]
        ) else { return }
        let body = url.path == "/large"
            ? String(repeating: "x", count: MetadataClient.maximumResponseBytes + 1)
            : "<title>Fixture article</title>"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
