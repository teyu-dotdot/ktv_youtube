import Foundation

/// Anything that can find karaoke versions of a song.
public protocol KaraokeSearching: Sendable {
    func search(_ query: String, limit: Int) async throws -> [KaraokeSearchResult]
}

public extension KaraokeSearching {
    func search(_ query: String) async throws -> [KaraokeSearchResult] {
        try await search(query, limit: 12)
    }
}

extension KaraokeSearchClient: KaraokeSearching {}

/// Searches YouTube directly, with nothing but an API key.
///
/// This is what lets the karaoke half of the app run with no helper service at
/// all — which in turn is what lets the whole thing be built and used from an
/// iPad, with no second machine. The vocal-removal fallback still needs the
/// service, because extracting a media URL is a different problem.
///
/// ## Quota
///
/// A Data API search costs 100 units against a default daily allowance of
/// 10,000, so the number of phrasings per user search is kept deliberately low
/// — two, chosen by the script the title is written in — giving roughly 50
/// searches a day. `videos.list` for durations costs 1 unit and is not worth
/// economising on.
public struct YouTubeDataAPISearchClient: KaraokeSearching {
    public let apiKey: String
    /// Phrasings to try per search. Each one costs 100 quota units.
    public let phrasingsPerSearch: Int
    private let session: URLSession

    public init(apiKey: String, phrasingsPerSearch: Int = 2, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.phrasingsPerSearch = max(1, phrasingsPerSearch)
        self.session = session
    }

    public func search(_ query: String, limit: Int) async throws -> [KaraokeSearchResult] {
        let phrasings = KaraokeRanker.queries(for: query, limit: phrasingsPerSearch)
        guard !phrasings.isEmpty else { return [] }

        // Keyed by video id so the same upload found twice is kept once.
        var candidates: [String: SearchItem] = [:]
        var firstError: Error?

        for phrasing in phrasings {
            do {
                for item in try await searchPage(phrasing) where candidates[item.videoID] == nil {
                    candidates[item.videoID] = item
                }
            } catch {
                // One phrasing failing shouldn't sink the whole search, but if
                // they all fail the user needs to hear about it.
                firstError = firstError ?? error
            }
        }

        if candidates.isEmpty, let firstError { throw firstError }

        let details = (try? await details(for: Array(candidates.keys))) ?? [:]

        let scored = candidates.values.map { item -> (SearchItem, VideoDetail?, KaraokeRanker.Ranking) in
            let detail = details[item.videoID]
            return (
                item,
                detail,
                KaraokeRanker.rank(
                    title: item.title, channel: item.channel, duration: detail?.duration
                )
            )
        }

        return scored
            // Scoring decides what's *eligible* — anything at or below zero is
            // signalling "original vocal" or "live" and never belongs in a
            // karaoke app. Ordering is then by popularity, because among tracks
            // that are all genuinely karaoke, the most-watched one is usually
            // the best-produced one. Sorting by score instead would bury a
            // million-view backing track under a keyword-stuffed title.
            .filter { $0.2.score > 0 }
            .sorted { ($0.1?.viewCount ?? 0) > ($1.1?.viewCount ?? 0) }
            .prefix(limit)
            .map { item, detail, ranking in
                KaraokeSearchResult(
                    videoID: item.videoID,
                    title: item.title,
                    channel: item.channel,
                    duration: detail?.duration,
                    thumbnailURL: item.thumbnailURL,
                    confidence: ranking.confidence,
                    viewCount: detail?.viewCount
                )
            }
    }

    // MARK: - Requests

    private func searchPage(_ phrasing: String) async throws -> [SearchItem] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")
        components?.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            // Videos that can't be embedded would fail in the player, so don't
            // let them into the results at all.
            URLQueryItem(name: "videoEmbeddable", value: "true"),
            URLQueryItem(name: "maxResults", value: "10"),
            URLQueryItem(name: "q", value: phrasing),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components?.url else { throw KaraokeSearchError.notConfigured }

        let data = try await fetch(url)
        let payload = try decode(SearchResponse.self, from: data)
        return payload.items.compactMap { item in
            guard let videoID = item.id.videoId,
                  YouTubeLink.isValidVideoID(videoID) else { return nil }
            return SearchItem(
                videoID: videoID,
                title: item.snippet.title.decodingHTMLEntities,
                channel: item.snippet.channelTitle?.decodingHTMLEntities ?? "",
                thumbnailURL: item.snippet.thumbnails?.best.flatMap(URL.init(string:))
            )
        }
    }

    /// Search results carry neither duration nor view count, so fetch both in
    /// one batched call. `videos.list` costs 1 unit against a search's 100.
    private func details(for videoIDs: [String]) async throws -> [String: VideoDetail] {
        guard !videoIDs.isEmpty else { return [:] }

        var result: [String: VideoDetail] = [:]
        // The API accepts up to 50 ids per call.
        for chunk in stride(from: 0, to: videoIDs.count, by: 50).map({
            Array(videoIDs[$0..<min($0 + 50, videoIDs.count)])
        }) {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")
            components?.queryItems = [
                URLQueryItem(name: "part", value: "contentDetails,statistics"),
                URLQueryItem(name: "id", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "key", value: apiKey)
            ]
            guard let url = components?.url else { continue }

            let data = try await fetch(url)
            let payload = try decode(VideosResponse.self, from: data)
            for item in payload.items {
                result[item.id] = VideoDetail(
                    duration: Self.parseISO8601Duration(item.contentDetails.duration),
                    viewCount: item.statistics?.viewCount.flatMap(Int.init)
                )
            }
        }
        return result
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KaraokeSearchError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
               let message = apiError.error.message {
                // The quota message is the one users will actually hit.
                if apiError.error.errors?.contains(where: { $0.reason == "quotaExceeded" }) == true {
                    throw KaraokeSearchError.failed(
                        reason: "Today's YouTube search quota is used up. It resets at "
                              + "midnight Pacific time."
                    )
                }
                throw KaraokeSearchError.failed(reason: message)
            }
            throw KaraokeSearchError.badResponse(statusCode: http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw KaraokeSearchError.malformedResponse
        }
    }

    /// Parses the `PT4M13S` form the API returns.
    static func parseISO8601Duration(_ raw: String) -> TimeInterval? {
        guard raw.hasPrefix("PT") || raw.hasPrefix("P") else { return nil }
        var total: TimeInterval = 0
        var number = ""
        var sawValue = false
        var inTime = false

        for character in raw {
            switch character {
            case "P": continue
            case "T": inTime = true
            case "0"..."9": number.append(character)
            default:
                guard let value = TimeInterval(number) else { return nil }
                switch character {
                case "H": total += value * 3600
                case "M": total += inTime ? value * 60 : value * 2_592_000
                case "S": total += value
                case "D": total += value * 86_400
                default: return nil
                }
                sawValue = true
                number = ""
            }
        }
        return sawValue ? total : nil
    }

    // MARK: - Payloads

    struct VideoDetail {
        let duration: TimeInterval?
        let viewCount: Int?
    }

    private struct SearchItem {
        let videoID: String
        let title: String
        let channel: String
        let thumbnailURL: URL?
    }

    private struct SearchResponse: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let id: ID
            let snippet: Snippet
            struct ID: Decodable { let videoId: String? }
            struct Snippet: Decodable {
                let title: String
                let channelTitle: String?
                let thumbnails: Thumbnails?
            }
            struct Thumbnails: Decodable {
                let high: Thumbnail?
                let medium: Thumbnail?
                let `default`: Thumbnail?
                struct Thumbnail: Decodable { let url: String }
                var best: String? { (high ?? medium ?? `default`)?.url }
            }
        }
    }

    private struct VideosResponse: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let id: String
            let contentDetails: ContentDetails
            let statistics: Statistics?
            struct ContentDetails: Decodable { let duration: String }
            // viewCount arrives as a string, and is absent when the uploader
            // has hidden their counts.
            struct Statistics: Decodable { let viewCount: String? }
        }
    }

    private struct APIErrorResponse: Decodable {
        let error: APIError
        struct APIError: Decodable {
            let message: String?
            let errors: [Detail]?
            struct Detail: Decodable { let reason: String? }
        }
    }
}

private extension String {
    /// The Data API returns titles with HTML entities in them (`&amp;`,
    /// `&#39;`), which would otherwise show up literally in the UI.
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        var output = self
        let replacements = [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")
        ]
        for (entity, character) in replacements {
            output = output.replacingOccurrences(of: entity, with: character)
        }
        return output
    }
}
