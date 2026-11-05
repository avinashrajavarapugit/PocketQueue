import Foundation
@testable import PocketQueueCore
import Testing

struct BookmarkDeepLinkTests {
    @Test func linksPreserveTheirGuestOrAccountScope() throws {
        let id = UUID()
        let owner = UUID()
        let guest = BookmarkDeepLink(bookmarkID: id)
        let cloud = BookmarkDeepLink(bookmarkID: id, accountID: owner)
        let guestURL = try #require(guest.url)
        let cloudURL = try #require(cloud.url)
        #expect(BookmarkDeepLink(url: guestURL) == guest)
        #expect(BookmarkDeepLink(url: cloudURL) == cloud)
        #expect(guest != cloud)
    }

    @Test func invalidOrAmbiguousAccountLinksAreRejected() throws {
        let id = UUID().uuidString
        let owner = UUID().uuidString
        for text in [
            "pocketqueue://bookmark/\(id)?account=not-a-uuid",
            "pocketqueue://bookmark/\(id)?account=\(owner)&account=\(owner)",
            "pocketqueue://bookmark/not-a-uuid",
            "pocketqueue://bookmark/extra/\(id)",
            "https://example.com/\(id)",
        ] {
            let url = try #require(URL(string: text))
            #expect(BookmarkDeepLink(url: url) == nil)
        }
    }
}
