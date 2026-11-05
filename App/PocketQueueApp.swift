import Network
import OSLog
import PocketQueueCore
import SwiftUI
import WidgetKit

@main
struct PocketQueueApp: App {
    private let startup: Result<CloudAccountModel, Error>

    init() {
        startup = Result {
            let store = try SharedEnvironment.makeStore()
            let configuration = try AppBackendConfiguration.load()
            let authentication: any CloudAuthenticating
            let metadata: any MetadataFetching
            let remoteFactory: @Sendable (UUID) -> any CloudBookmarkTransport
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    authentication = try FixtureAuthentication(
                        fileURL: SharedEnvironment.databaseURL().deletingLastPathComponent()
                            .appending(path: "account.json")
                    )
                    metadata = DemoMetadataClient()
                    let injectConflict = ProcessInfo.processInfo.arguments.contains("--sync-conflict")
                    remoteFactory = { _ in FixtureCloudTransport(conflictOnFirstWrite: injectConflict) }
                } else {
                    authentication = try SupabaseAuthentication(
                        configuration: configuration,
                        keychainService: LiveBackendTestSupport.enabled
                            ? "com.avinashrajavarapu.pocketqueue.auth.backend-test"
                            : "com.avinashrajavarapu.pocketqueue.auth"
                    )
                    metadata = MetadataClient()
                    remoteFactory = { id in
                        GraphQLBookmarkClient(
                            configuration: configuration,
                            authentication: authentication,
                            accountID: id
                        )
                    }
                }
            #else
                authentication = try SupabaseAuthentication(configuration: configuration)
                metadata = MetadataClient()
                remoteFactory = { id in
                    GraphQLBookmarkClient(configuration: configuration, authentication: authentication, accountID: id)
                }
            #endif
            return CloudAccountModel(
                store: store, authentication: authentication, metadata: metadata, remoteFactory: remoteFactory
            ) {
                WidgetCenter.shared.reloadTimelines(ofKind: SharedEnvironment.widgetKind)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case let .success(model):
                AccountRootView(account: model)
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

private struct AppBackendConfiguration: Decodable {
    let url: URL
    let publishableKey: String

    static func load() throws -> BackendConfiguration {
        guard let file = Bundle.main.url(forResource: "Backend", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        return try BackendConfiguration(url: configuration.url, publishableKey: configuration.publishableKey)
    }
}

private struct AccountRootView: View {
    @Bindable var account: CloudAccountModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmCredentialReset = false
    @State private var pendingBookmark: BookmarkDeepLink?

    var body: some View {
        Group {
            if let library = account.library {
                LibraryView(model: library, account: account, pendingBookmark: $pendingBookmark)
                    .id(ObjectIdentifier(library))
            } else if let error = account.errorMessage {
                ContentUnavailableView {
                    Label("Library unavailable", systemImage: "lock.shield")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await account.restore() } }
                    Button("Reset sign-in and use on-device library") { confirmCredentialReset = true }
                        .accessibilityIdentifier("recoverAccountButton")
                }
            } else {
                ProgressView("Opening your library")
            }
        }
        .task {
            await account.restore()
            #if DEBUG
                if LiveBackendTestSupport.enabled {
                    await LiveBackendTestSupport.signIn(account)
                }
            #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            account.setForeground(phase == .active)
        }
        .onOpenURL { url in
            if url.scheme == "pocketqueue", url.host() == "auth" {
                Task { await account.handleCallback(url) }
            } else if let bookmark = BookmarkDeepLink(url: url) {
                pendingBookmark = bookmark
            } else {
                account.errorMessage = "PocketQueue cannot open this link."
            }
        }
        .sheet(isPresented: $account.isRecoveringPassword) { PasswordRecoveryView(account: account) }
        .confirmationDialog(
            "Clear the saved sign-in? Account bookmarks and queued changes will remain separate until you sign in again.",
            isPresented: $confirmCredentialReset, titleVisibility: .visible
        ) {
            Button("Reset sign-in") { Task { await account.recoverToGuestPreservingChanges() } }
        }
        .task {
            let changes = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let monitor = NWPathMonitor()
                monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
                continuation.onTermination = { _ in monitor.cancel() }
                monitor.start(queue: DispatchQueue(label: "PocketQueue.connectivity"))
            }
            for await online in changes where online {
                account.requestSync()
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
