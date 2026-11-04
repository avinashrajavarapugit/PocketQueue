import OSLog
import SwiftUI

struct ThumbnailView: View {
    let url: URL?
    @State private var image: UIImage?
    private let logger = Logger(subsystem: "com.avinashrajavarapu.pocketqueue", category: "thumbnail")

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "bookmark.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.indigo.opacity(0.08))
            }
        }
        .frame(width: 64, height: 72)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            do {
                image = try await ImageLoader.shared.image(for: url)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    logger.notice("Optional thumbnail unavailable; using bookmark placeholder")
                }
            }
        }
    }
}
