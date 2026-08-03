import Foundation

/// Reads the contents of a YouTube playlist.
///
/// This is what turns a collaborative playlist into a shared karaoke queue.
/// Everyone adds songs from the YouTube app on their own phone; the iPad reads
/// the list back and plays it. No accounts in this app, no server, no sync
/// protocol — YouTube already solved the hard part, and the only piece missing
/// was reading the result.
///
/// `playlistItems.list` costs 1 quota unit against the same 10,000/day
/// allowance a search spends 100 on, so refreshing often is essentially free.
/// That matters: the list has to be re-read while people are still adding to it.
public struct YouTubePlaylistClient: Sendable {
    public let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Songs in the playlist, in playlist order.
    ///
    /// Deleted and private videos are dropped: they appear in the list as
    /// placeholders with no usable id, and queueing one would stall the night
    /// on a video that can't play.
    public func items(
        in playlist: YouTubePlaylist,
        limit: Int = 50
    ) async throws -> [KaraokeSearchResult] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")
        components?.queryItems = [
            URLQueryItem(name: "part", value: "snippet,contentDetails,status"),
            URLQueryItem(name: "playlistId", value: playlist.listID),
            URLQueryItem(name: "maxResults", value: String(max(1, min(50, limit)))),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components?.url else { throw KaraokeSearchError.notConfigured }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // The whole point is seeing songs other people just added, so a cached
        // response is worse than no response.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KaraokeSearchError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
               let message = apiError.error.message {
                if http.statusCode == 404 {
                    throw KaraokeSearchError.failed(
                        reason: "That playlist can't be read. It may have been deleted, "
                              + "or set to private — a shared playlist has to be unlisted "
                              + "or public for the app to see it."
                    )
                }
                throw KaraokeSearchError.failed(reason: message)
            }
            throw KaraokeSearchError.badResponse(statusCode: http.statusCode)
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw KaraokeSearchError.malformedResponse
        }

        return payload.items.compactMap { item in
            let videoID = item.contentDetails?.videoId ?? ""
            guard YouTubeLink.isValidVideoID(videoID) else { return nil }
            // "Deleted video" / "Private video" placeholders keep their slot in
            // the list but can never play.
            let title = item.snippet?.title ?? ""
            guard title != "Deleted video", title != "Private video" else { return nil }

            return KaraokeSearchResult(
                videoID: videoID,
                title: title.isEmpty ? videoID : title,
                channel: item.snippet?.videoOwnerChannelTitle ?? "",
                duration: nil,
                thumbnailURL: item.snippet?.thumbnails?.best.flatMap(URL.init(string:))
                    ?? YouTubeLink(videoID: videoID).thumbnailURL,
                confidence: .low
            )
        }
    }

    // MARK: - Payloads

    private struct Payload: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let snippet: Snippet?
            let contentDetails: ContentDetails?
            struct Snippet: Decodable {
                let title: String?
                let videoOwnerChannelTitle: String?
                let thumbnails: Thumbnails?
            }
            struct ContentDetails: Decodable { let videoId: String? }
            struct Thumbnails: Decodable {
                let high: Thumbnail?
                let medium: Thumbnail?
                let `default`: Thumbnail?
                struct Thumbnail: Decodable { let url: String }
                var best: String? { (high ?? medium ?? `default`)?.url }
            }
        }
    }

    private struct APIErrorResponse: Decodable {
        let error: APIError
        struct APIError: Decodable { let message: String? }
    }
}

public extension ResolverConfiguration {
    /// Builds a playlist reader, or nil without an API key.
    ///
    /// Unlike search, there's no helper-service fallback: reading a playlist is
    /// one cheap API call, and the service was never given an endpoint for it.
    func makePlaylistClient(session: URLSession = .shared) -> YouTubePlaylistClient? {
        let key = youTubeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return YouTubePlaylistClient(apiKey: key, session: session)
    }
}
