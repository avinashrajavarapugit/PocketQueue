import PocketQueueCore
import SafariServices
import SwiftUI

struct BookmarkDetailView: View {
    let model: LibraryModel
    let bookmarkID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showBrowser = false
    @State private var showDeleteConfirmation = false
    @State private var showEdit = false

    private var bookmark: Bookmark? {
        model.bookmarks.first { $0.id == bookmarkID }
    }

    var body: some View {
        Group {
            if let bookmark {
                detail(bookmark)
            } else if model.isLoading {
                ProgressView("Opening bookmark")
            } else {
                ContentUnavailableView("Bookmark unavailable", systemImage: "bookmark.slash",
                                       description: Text("It may have been deleted. Return to your library."))
            }
        }
        .navigationTitle("Saved link")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ bookmark: Bookmark) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(bookmark.domain).font(.subheadline).foregroundStyle(.secondary)
                    Text(bookmark.title).font(.title2.bold()).textSelection(.enabled)
                    Text(bookmark.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Open original", systemImage: "safari") { showBrowser = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("openOriginalButton")
                }
                .padding(.vertical, 8)
            }
            Section("Your library") {
                Button(
                    bookmark.isRead ? "Mark unread" : "Mark as read",
                    systemImage: bookmark.isRead ? "circle" : "checkmark.circle"
                ) {
                    Task { await model.update(bookmark.id, change: .read(!bookmark.isRead)) }
                }
                .accessibilityIdentifier("toggleReadButton")
                Button(
                    bookmark.isFavorite ? "Remove favorite" : "Add to favorites",
                    systemImage: bookmark.isFavorite ? "star.fill" : "star"
                ) {
                    Task { await model.update(bookmark.id, change: .favorite(!bookmark.isFavorite)) }
                }
                .accessibilityIdentifier("toggleFavoriteButton")
            }
            Section("Your notes") {
                Text(bookmark.note.isEmpty ? "No note yet. What made this worth saving?" : bookmark.note)
                    .foregroundStyle(bookmark.note.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                if !bookmark.tags.isEmpty {
                    Text(bookmark.tags.map { "#\($0)" }.joined(separator: " ")).foregroundStyle(.indigo)
                }
                Button("Edit notes and tags", systemImage: "square.and.pencil") { showEdit = true }
                    .accessibilityIdentifier("editNotesButton")
            }
            if bookmark.metadataState != .ready {
                Section("Preview") {
                    Text(bookmark
                        .metadataMessage ?? "Your link is safely saved. Open the app online to fetch its preview.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("metadataStatus")
                    if bookmark.metadataState == .failed {
                        Button("Retry preview", systemImage: "arrow.clockwise") {
                            Task { await model.update(bookmark.id, change: .retryMetadata) }
                        }
                    }
                }
            }
            Section {
                ShareLink(item: bookmark.url)
                    .accessibilityIdentifier("shareBookmarkButton")
                Button("Delete bookmark", systemImage: "trash", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .accessibilityIdentifier("deleteBookmarkButton")
            } footer: {
                Text("""
                Saved \(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened)). \
                Links and notes work offline; original pages require a connection.
                """)
            }
        }
        .sheet(isPresented: $showBrowser) { SafariView(url: bookmark.url).ignoresSafeArea() }
        .sheet(isPresented: $showEdit) { EditBookmarkView(model: model, bookmark: bookmark) }
        .confirmationDialog(
            "Delete this bookmark and its notes?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.delete(bookmark.id) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context _: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_: SFSafariViewController, context _: Context) {}
}

private struct EditBookmarkView: View {
    let model: LibraryModel
    let bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var tags = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Your note", text: $note, axis: .vertical)
                    .lineLimit(4 ... 12)
                    .accessibilityIdentifier("editNoteField")
                TextField("Tags, separated by commas", text: $tags)
                    .textInputAutocapitalization(.never)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Notes & tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            if await model.update(
                                bookmark.id,
                                change: .details(note: note, tags: tags.components(separatedBy: ","))
                            ) {
                                dismiss()
                            } else {
                                error = model.errorMessage
                                model.errorMessage = nil
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("saveNotesButton")
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                note = bookmark.note
                tags = bookmark.tags.joined(separator: ", ")
            }
        }
    }
}
