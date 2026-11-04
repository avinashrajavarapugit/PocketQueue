import PocketQueueCore
import SwiftUI

struct BookmarkRow: View {
    let bookmark: Bookmark
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                ThumbnailView(url: bookmark.imageURL)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(bookmark.domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if bookmark.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(bookmark.title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                if !bookmark.tags.isEmpty {
                    Text(bookmark.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.indigo)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                if bookmark.metadataState == .failed {
                    Label("Saved. Preview unavailable.", systemImage: "wifi.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if bookmark.metadataState == .pending {
                    Text("Saved. Preview pending.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
