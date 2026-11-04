import Foundation

public struct LinkMetadata: Equatable, Sendable {
    public let title: String
    public let imageURL: URL?

    public init(title: String, imageURL: URL? = nil) {
        self.title = title
        self.imageURL = imageURL
    }
}

public protocol MetadataFetching: Sendable {
    func fetch(_ url: URL) async throws -> LinkMetadata
}

public enum MetadataError: LocalizedError, Equatable, Sendable {
    case insecureURL
    case httpStatus(Int)
    case unsupportedContent
    case tooLarge
    case noTitle

    public var errorDescription: String? {
        switch self {
        case .insecureURL: "Preview fetching requires HTTPS. Your original link is saved."
        case let .httpStatus(code): "The website returned HTTP \(code). Your link is still saved."
        case .unsupportedContent: "This link is not an HTML page. You can still open the original."
        case .tooLarge: "This page is too large to preview. Your link is still saved."
        case .noTitle: "This website did not provide a readable title. Your link is still saved."
        }
    }
}

public struct MetadataClient: MetadataFetching {
    private let session: URLSession
    public static let maximumResponseBytes = 524_288

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func fetch(_ url: URL) async throws -> LinkMetadata {
        guard url.scheme?.lowercased() == "https" else { throw MetadataError.insecureURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("PocketQueue/1.0", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw MetadataError.unsupportedContent }
        guard response.url?.scheme == "https" else { throw MetadataError.insecureURL }
        guard (200 ... 299).contains(response.statusCode) else {
            throw MetadataError.httpStatus(response.statusCode)
        }
        guard ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else {
            throw MetadataError.unsupportedContent
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumResponseBytes else { throw MetadataError.tooLarge }
            data.append(byte)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw MetadataError.unsupportedContent }
        return try MetadataParser.parse(html, baseURL: response.url ?? url)
    }
}

public enum MetadataParser {
    /// This bounded preview parser intentionally does not extract articles, execute scripts, or render HTML.
    public static func parse(_ html: String, baseURL: URL) throws -> LinkMetadata {
        let metaTags = try matches("<meta\\b[^>]*>", in: html)
        var values: [String: String] = [:]
        for tag in metaTags {
            let attributes = try attributes(in: tag)
            if let key = attributes["property"] ?? attributes["name"], let value = attributes["content"] {
                values[key.lowercased()] = value
            }
        }
        let fallback = try matches("<title\\b[^>]*>(.*?)</title\\s*>", in: html, capture: 1).first
        guard let rawTitle = values["og:title"] ?? values["twitter:title"] ?? fallback else {
            throw MetadataError.noTitle
        }
        let title = decodeEntities(rawTitle)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty else { throw MetadataError.noTitle }
        let image = (values["og:image"] ?? values["twitter:image"])
            .flatMap { URL(string: decodeEntities($0), relativeTo: baseURL)?.absoluteURL }
        let safeImage = image.flatMap {
            $0.scheme == "https" && $0.user == nil && $0.password == nil ? $0 : nil
        }
        return LinkMetadata(title: String(title.prefix(300)), imageURL: safeImage)
    }

    private static func attributes(in tag: String) throws -> [String: String] {
        let expression = try NSRegularExpression(
            pattern: "([\\w:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
            options: [.caseInsensitive]
        )
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let keyRange = Range(match.range(at: 1), in: tag) else { continue }
            let valueRange = Range(match.range(at: 2), in: tag) ?? Range(match.range(at: 3), in: tag)
            if let valueRange {
                result[String(tag[keyRange]).lowercased()] = String(tag[valueRange])
            }
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String, capture: Int = 0) throws -> [String] {
        let expression = try NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: capture), in: text).map { String(text[$0]) }
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&"),
        ] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}
