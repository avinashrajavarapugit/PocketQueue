import Foundation

public struct BookmarkDeepLink: Hashable, Sendable {
    public let bookmarkID: UUID
    public let accountID: UUID?

    public init(bookmarkID: UUID, accountID: UUID? = nil) {
        self.bookmarkID = bookmarkID
        self.accountID = accountID
    }

    public init?(url: URL) {
        guard url.scheme == "pocketqueue", url.host() == "bookmark",
              url.pathComponents.count == 2, let id = UUID(uuidString: url.lastPathComponent),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let accounts = components.queryItems?.filter { $0.name == "account" } ?? []
        guard accounts.count <= 1 else { return nil }
        if let account = accounts.first {
            guard let text = account.value, let owner = UUID(uuidString: text) else { return nil }
            accountID = owner
        } else {
            accountID = nil
        }
        bookmarkID = id
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "pocketqueue"
        components.host = "bookmark"
        components.path = "/\(bookmarkID.uuidString)"
        if let accountID {
            components.queryItems = [URLQueryItem(name: "account", value: accountID.uuidString)]
        }
        return components.url
    }
}
