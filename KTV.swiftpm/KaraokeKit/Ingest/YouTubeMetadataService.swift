import Foundation

/// Title and channel for a video, from YouTube's public oEmbed endpoint.
public struct YouTubeMetadata: Equatable, Sendable {
    public var title: String
    public var author: String?
    public var thumbnailURL: URL?
}

/// Fetches display metadata for a link so the library row can show a real title
/// while the audio is still downloading.
///
/// oEmbed is a documented public endpoint and needs no API key. It returns
/// nothing but display metadata — no media URLs — so this is purely cosmetic
/// and every call site treats failure as non-fatal.
public struct YouTubeMetadataService: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func metadata(for link: YouTubeLink) async -> YouTubeMetadata? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: link.canonicalURL.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(OEmbedPayload.self, from: data)
        else { return nil }

        return YouTubeMetadata(
            title: payload.title,
            author: payload.authorName,
            thumbnailURL: payload.thumbnailURL.flatMap(URL.init(string:)) ?? link.thumbnailURL
        )
    }

    private struct OEmbedPayload: Decodable {
        let title: String
        let authorName: String?
        let thumbnailURL: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
        }
    }
}
