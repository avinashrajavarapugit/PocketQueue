import AppIntents
import OSLog
import PocketQueueCore
import SwiftUI
import WidgetKit

struct ReadingEntry: TimelineEntry {
    let date: Date
    let bookmark: Bookmark?
    let unavailable: Bool
    var accountID: UUID?
}

struct ReadingConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource {
        "Read next"
    }

    static var description: IntentDescription {
        "Show a saved link from your reading queue."
    }
}

struct ReadingProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> ReadingEntry {
        ReadingEntry(date: .now, bookmark: nil, unavailable: false)
    }

    func snapshot(for _: ReadingConfiguration, in _: Context) async -> ReadingEntry {
        await loadEntry()
    }

    func timeline(for _: ReadingConfiguration, in _: Context) async -> Timeline<ReadingEntry> {
        let entry = await loadEntry()
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1800)))
    }

    private func loadEntry() async -> ReadingEntry {
        do {
            let store = try SharedEnvironment.makeStore()
            let unread = try await store.all().filter { !$0.isRead }
            return ReadingEntry(
                date: .now, bookmark: unread.first(where: \.isFavorite) ?? unread.last,
                unavailable: false, accountID: store.accountID
            )
        } catch {
            Logger(subsystem: "com.avinashrajavarapu.pocketqueue", category: "widget")
                .error("Widget could not read shared library")
            return ReadingEntry(date: .now, bookmark: nil, unavailable: true)
        }
    }
}

struct ReadingWidgetView: View {
    let entry: ReadingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("READ NEXT", systemImage: "bookmark.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.indigo)
            if let bookmark = entry.bookmark {
                Text(bookmark.title)
                    .font(.headline)
                    .lineLimit(4)
                Spacer(minLength: 0)
                Text(bookmark.domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(entry.unavailable ? "Open PocketQueue to check your library." : "Make room for a good read.")
                    .font(.headline)
                Text(entry.unavailable ? "Library unavailable" : "Save a link to get started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.bookmark.flatMap { BookmarkDeepLink(bookmarkID: $0.id, accountID: entry.accountID).url })
        .privacySensitive()
    }
}

@main
struct PocketQueueWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: SharedEnvironment.widgetKind, intent: ReadingConfiguration.self, provider: ReadingProvider()
        ) { entry in
            ReadingWidgetView(entry: entry)
        }
        .configurationDisplayName("Read next")
        .description("A little nudge toward something worth reading.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
