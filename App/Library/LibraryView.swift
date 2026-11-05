import OSLog
import PocketQueueCore
import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var path: [UUID] = []
    @State private var pendingBookmarkID: UUID?
    private let logger = Logger(subsystem: "com.avinashrajavarapu.pocketqueue", category: "navigation")

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    header
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 10, leading: 4, bottom: 18, trailing: 4))
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            filterPicker.pickerStyle(.menu)
                        } else {
                            filterPicker.pickerStyle(.segmented)
                        }
                    }
                    .accessibilityIdentifier("libraryFilter")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                .listRowSeparator(.hidden)

                if let notice = model.notice {
                    Section {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("saveNotice")
                    }
                }

                if model.visibleBookmarks.isEmpty {
                    Section {
                        emptyState
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(model.visibleBookmarks) { bookmark in
                            NavigationLink(value: bookmark.id) {
                                BookmarkRow(bookmark: bookmark)
                            }
                            .accessibilityIdentifier("bookmark-\(bookmark.id)")
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await model.update(bookmark.id, change: .read(!bookmark.isRead)) }
                                } label: {
                                    Label(bookmark.isRead ? "Unread" : "Read", systemImage: "checkmark")
                                }
                                .tint(.teal)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    Task { await model.update(bookmark.id, change: .favorite(!bookmark.isFavorite)) }
                                } label: {
                                    Label("Favorite", systemImage: "star")
                                }
                                .tint(.orange)
                            }
                        }
                    } header: {
                        Text(
                            "\(model.visibleBookmarks.count) saved \(model.visibleBookmarks.count == 1 ? "link" : "links")"
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("PocketQueue")
            .searchable(text: $model.searchText, prompt: "Search links, notes, or tags")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .accessibilityIdentifier("settingsButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save link", systemImage: "plus") { showAdd = true }
                        .accessibilityIdentifier("addBookmarkButton")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                BookmarkDetailView(model: model, bookmarkID: id)
            }
            .sheet(isPresented: $showAdd) { AddBookmarkView(model: model) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { model.requestRefresh() }
        }
        .task(id: model.refreshID) {
            if scenePhase == .active {
                if let bookmarkID = pendingBookmarkID {
                    await model.load()
                    guard !Task.isCancelled else { return }
                    path = [bookmarkID]
                    pendingBookmarkID = nil
                    logger.info("Opened queued bookmark deep link")
                }
                await model.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.requestRefresh()
            if phase != .active {
                model.notice = nil
            }
        }
        .onOpenURL { url in
            guard url.scheme == "pocketqueue", url.host() == "bookmark",
                  let id = UUID(uuidString: url.lastPathComponent) else { return }
            logger.info("Received bookmark deep link")
            pendingBookmarkID = id
            model.requestRefresh()
        }
        .alert("Something needs attention", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: {
                if !$0 {
                    model.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("YOUR PERSONAL READING SPACE", systemImage: "tray.full.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.indigo)
            Text("Good things,\nfor later.")
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
                .accessibilityAddTraits(.isHeader)
            Text("Save the interesting. Come back with intention.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("Saved on your device. No account needed.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var filterPicker: some View {
        Picker("Library filter", selection: $model.filter) {
            ForEach(LibraryFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading, model.bookmarks.isEmpty {
            ProgressView("Opening your library")
                .frame(maxWidth: .infinity)
        } else if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.bookmarks.isEmpty {
            ContentUnavailableView {
                Label("Your next good read starts here", systemImage: "bookmark")
            } description: {
                Text("Save an article, a video, or a useful reference. Your links and notes stay available offline.")
            } actions: {
                Button("Save your first link") { showAdd = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "Nothing in \(model.filter.rawValue.lowercased()) yet",
                systemImage: "tray",
                description: Text("Try another filter, or save something new.")
            )
        }
    }
}
