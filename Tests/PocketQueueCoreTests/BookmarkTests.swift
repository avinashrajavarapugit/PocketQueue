import Foundation
@testable import PocketQueueCore
import Testing

struct BookmarkTests {
    @Test func canonicalURLsPreserveMeaningfulQueryAndFragment() throws {
        #expect(try BookmarkURL.parse(" HTTPS://Example.COM:443 ").absoluteString == "https://example.com/")
        #expect(try BookmarkURL.parse("example.com/guide?q=swift#actors")
            .absoluteString == "https://example.com/guide?q=swift#actors")
    }

    @Test(arguments: [
        "",
        "not a url",
        "javascript:alert(1)",
        "file:///etc/hosts",
        "https://user:secret@example.com",
        "https://",
    ])
    func rejectsInvalidURLs(_ input: String) {
        #expect(throws: BookmarkError.invalidURL) { try BookmarkURL.parse(input) }
    }

    @Test func normalizesTagsAndSearchesAllUserContent() throws {
        let bookmark = try Bookmark(
            url: BookmarkURL.parse("example.com"), title: "Swift Concurrency",
            note: "Read about actors", tags: [" Swift ", "swift", "", "iOS"]
        )
        #expect(bookmark.tags == ["ios", "swift"])
        #expect(bookmark.matches("SWIFT actors"))
        #expect(bookmark.matches("example.com"))
        #expect(!bookmark.matches("Kotlin"))
    }
}
