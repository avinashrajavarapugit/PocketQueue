import OSLog
import PocketQueueCore
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let content = ShareBookmarkView(
            loadInput: { [weak self] in
                guard let self else { throw ShareError.noLink }
                return try await self.sharedLink()
            },
            complete: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            cancel: { [weak self] in self?.extensionContext?.cancelRequest(withError: ShareError.cancelled) }
        )
        let host = UIHostingController(rootView: content)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func sharedLink() async throws -> String {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        for type in [UTType.url.identifier, UTType.plainText.identifier] {
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) {
                return try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let url = item as? URL {
                            continuation.resume(returning: url.absoluteString)
                        } else if let text = item as? String {
                            continuation.resume(returning: text)
                        } else {
                            continuation.resume(throwing: ShareError.noLink)
                        }
                    }
                }
            }
        }
        throw ShareError.noLink
    }
}

private enum ShareError: LocalizedError {
    case noLink, cancelled

    var errorDescription: String? {
        switch self {
        case .noLink: "No link was provided. Paste an http or https URL below."
        case .cancelled: "Sharing was cancelled."
        }
    }
}

private struct ShareBookmarkView: View {
    let loadInput: @MainActor () async throws -> String
    let complete: @MainActor () -> Void
    let cancel: @MainActor () -> Void
    @State private var url = ""
    @State private var note = ""
    @State private var tags = ""
    @State private var error: String?
    @State private var isSaving = false
    @State private var duplicate = false
    private let logger = Logger(subsystem: "com.avinashrajavarapu.pocketqueue", category: "share")

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("A good find. Keep it.", systemImage: "bookmark.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.indigo)
                    TextField("Link URL", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("shareURLField")
                }
                Section("Optional") {
                    TextField("Why save this?", text: $note, axis: .vertical)
                    TextField("Tags, separated by commas", text: $tags)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Text(
                        "Saved directly to your device. No network connection required. Preview loads when you open PocketQueue."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("PocketQueue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save", action: save)
                        .disabled(url.isEmpty || isSaving)
                        .accessibilityIdentifier("shareSaveButton")
                }
            }
            .task {
                do {
                    url = try await loadInput()
                } catch {
                    self.error = error.localizedDescription
                    logger.notice("Shared input could not be loaded")
                }
            }
            .alert("Already in your library", isPresented: $duplicate) {
                Button("Done", action: complete)
            } message: {
                Text("Your existing bookmark and notes have been kept unchanged.")
            }
        }
        .tint(.indigo)
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let parsed = try BookmarkURL.parse(url)
                let store = try SharedEnvironment.makeStore()
                let result = try await store.save(url: parsed, note: note, tags: tags.components(separatedBy: ","))
                WidgetCenter.shared.reloadTimelines(ofKind: SharedEnvironment.widgetKind)
                if result.inserted {
                    complete()
                } else {
                    duplicate = true
                }
            } catch {
                self.error = error.localizedDescription
                logger.error("Share save failed; keeping input available for retry")
            }
        }
    }
}
