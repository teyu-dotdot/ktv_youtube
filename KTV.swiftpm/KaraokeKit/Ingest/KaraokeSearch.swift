import Foundation

/// One candidate karaoke video from a search.
public struct KaraokeSearchResult: Identifiable, Equatable, Hashable, Sendable {
    /// How sure the ranking is that this is an instrumental and not the
    /// original recording.
    public enum Confidence: String, Codable, Sendable {
        case high, medium, low

        /// Short label for the row. Nil where a badge would be noise.
        public var badge: String? {
            switch self {
            case .high: return "Karaoke"
            case .medium: return "Probably karaoke"
            case .low: return nil
            }
        }
    }

    public let videoID: String
    public let title: String
    public let channel: String
    public let duration: TimeInterval?
    public let thumbnailURL: URL?
    public let confidence: Confidence
    /// Lifetime views, used to order results. Nil when the backend didn't say.
    public let viewCount: Int?

    public var id: String { videoID }

    public var link: YouTubeLink { YouTubeLink(videoID: videoID) }

    public init(
        videoID: String,
        title: String,
        channel: String,
        duration: TimeInterval?,
        thumbnailURL: URL?,
        confidence: Confidence,
        viewCount: Int? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.channel = channel
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.confidence = confidence
        self.viewCount = viewCount
    }

    /// "1.2M views" — compact enough for a list row.
    public var viewCountDescription: String? {
        guard let viewCount else { return nil }
        switch viewCount {
        case 1_000_000...:
            return String(format: "%.1fM views", Double(viewCount) / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK views", Double(viewCount) / 1_000)
        default:
            return "\(viewCount) views"
        }
    }
}

public enum KaraokeSearchError: LocalizedError, Equatable {
    case notConfigured
    case badResponse(statusCode: Int)
    case malformedResponse
    case failed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No search service is configured. Add one in Settings."
        case .badResponse(let statusCode):
            return "The search service returned an error (HTTP \(statusCode))."
        case .malformedResponse:
            return "The search service returned a response the app couldn't read."
        case .failed(let reason):
            return reason
        }
    }
}

/// Finds karaoke versions of a song.
///
/// Searching happens on the same service that does resolution, because it needs
/// the same YouTube access the app doesn't have. Ranking happens there too —
/// the keyword lists are long, language-specific, and much easier to tune
/// server-side than in a shipped binary.
public struct KaraokeSearchClient: Sendable {
    public let baseURL: URL
    public let accessToken: String?
    private let session: URLSession

    public init(baseURL: URL, accessToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.session = session
    }

    /// - Parameter query: song title, optionally with the artist.
    public func search(_ query: String, limit: Int) async throws -> [KaraokeSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else { throw KaraokeSearchError.notConfigured }

        var request = URLRequest(url: url)
        // Four upstream searches run per request, so allow for a slow one.
        request.timeoutInterval = 45
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KaraokeSearchError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data),
               let message = payload.error {
                throw KaraokeSearchError.failed(reason: message)
            }
            throw KaraokeSearchError.badResponse(statusCode: http.statusCode)
        }

        let payload: SearchPayload
        do {
            payload = try JSONDecoder().decode(SearchPayload.self, from: data)
        } catch {
            throw KaraokeSearchError.malformedResponse
        }

        return payload.results.compactMap { item in
            guard YouTubeLink.isValidVideoID(item.videoID) else { return nil }
            return KaraokeSearchResult(
                videoID: item.videoID,
                title: item.title,
                channel: item.channel ?? "",
                duration: item.duration,
                thumbnailURL: item.thumbnail.flatMap(URL.init(string:)),
                confidence: item.confidence ?? .low,
                viewCount: item.viewCount
            )
        }
    }

    private struct SearchPayload: Decodable {
        let results: [Item]

        struct Item: Decodable {
            let videoID: String
            let title: String
            let channel: String?
            let duration: TimeInterval?
            let thumbnail: String?
            let confidence: KaraokeSearchResult.Confidence?
            let viewCount: Int?

            enum CodingKeys: String, CodingKey {
                case videoID = "video_id"
                case viewCount = "view_count"
                case title, channel, duration, thumbnail, confidence
            }
        }
    }

    private struct ErrorPayload: Decodable {
        let error: String?
    }
}

public extension ResolverConfiguration {
    /// Picks a search backend, or nil when neither is configured.
    ///
    /// An API key wins when both are set: it takes the helper service out of
    /// the loop for the karaoke path entirely, which is the difference between
    /// needing a second machine and not.
    func makeSearchClient(session: URLSession = .shared) -> KaraokeSearching? {
        let key = youTubeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            return YouTubeDataAPISearchClient(apiKey: key, session: session)
        }
        guard let baseURL else { return nil }
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return KaraokeSearchClient(
            baseURL: baseURL,
            accessToken: token.isEmpty ? nil : token,
            session: session
        )
    }
}
