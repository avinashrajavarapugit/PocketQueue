import OSLog
import PocketQueueCore
import SwiftUI
import WidgetKit

@main
struct PocketQueueApp: App {
    private let startup: Result<LibraryModel, Error>

    init() {
        startup = Result {
            let store = try SharedEnvironment.makeStore()
            let metadata: any MetadataFetching
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    metadata = DemoMetadataClient()
                } else {
                    metadata = MetadataClient()
                }
            #else
                metadata = MetadataClient()
            #endif
            return LibraryModel(store: store, metadata: metadata) {
                WidgetCenter.shared.reloadTimelines(ofKind: SharedEnvironment.widgetKind)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case let .success(model):
                LibraryView(model: model)
                    .tint(.indigo)
            case let .failure(error):
                ContentUnavailableView(
                    "Library unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(error.localizedDescription)
                )
                .task {
                    Logger(subsystem: "com.avinashrajavarapu.pocketqueue", category: "startup")
                        .error("Shared storage configuration failed")
                }
            }
        }
    }
}

#if DEBUG
    private struct DemoMetadataClient: MetadataFetching {
        func fetch(_ url: URL) async throws -> LinkMetadata {
            if url.host() == "preview-fails.example" {
                throw MetadataError.httpStatus(503)
            }
            return LinkMetadata(title: "Saved article from \(url.host() ?? "website")")
        }
    }
#endif
