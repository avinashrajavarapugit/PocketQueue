import Foundation
import PocketQueueCore

enum SharedEnvironment {
    static let widgetKind = "PocketQueueReadNext"

    static var isStandalone: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "PocketQueueAppGroup") as? String ?? "").isEmpty
    }

    static func makeStore() throws -> BookmarkStore {
        let url = try databaseURL()
        return try BookmarkStore(databaseURL: url, accountID: BookmarkStore.activeAccountID(databaseURL: url))
    }

    static func databaseURL() throws -> URL {
        let container: URL
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                let name = ProcessInfo.processInfo.environment["POCKETQUEUE_TEST_ID"] ?? "default"
                let root = try FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
                )
                return root.appending(path: "UITests/\(name)/library.sqlite")
            }
        #endif
        if let group = Bundle.main.object(forInfoDictionaryKey: "PocketQueueAppGroup") as? String,
           !group.isEmpty
        {
            guard let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw ConfigurationError.appGroupUnavailable
            }
            container = shared
        } else {
            guard Bundle.main.bundleURL.pathExtension != "appex" else {
                throw ConfigurationError.appGroupUnavailable
            }
            container = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
        }
        return container.appending(path: "Library/library.sqlite")
    }
}

enum ConfigurationError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        "Shared storage is unavailable. Check App Group signing, or build the PocketQueueLocal scheme for standalone use."
    }
}
