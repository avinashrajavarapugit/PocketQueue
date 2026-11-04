import Foundation
import ImageIO
import UIKit

actor ImageLoader {
    static let shared = ImageLoader()
    private let session: URLSession
    private let memory = NSCache<NSURL, UIImage>()
    private let maxBytes = 2_097_152

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1024 * 1024, diskCapacity: 20 * 1024 * 1024,
            directory: nil
        )
        session = URLSession(configuration: configuration)
        memory.totalCostLimit = 12 * 1024 * 1024
    }

    func image(for url: URL) async throws -> UIImage {
        guard url.scheme == "https" else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        if let cached = memory.object(forKey: url as NSURL) {
            return cached
        }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode),
              response.mimeType?.hasPrefix("image/") == true else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 240,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        let image = UIImage(cgImage: thumbnail)
        memory.setObject(image, forKey: url as NSURL, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
}
