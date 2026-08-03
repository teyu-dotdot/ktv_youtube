import Foundation

/// What a resolver hands back for a YouTube link.
public struct ResolvedMedia: Equatable, Sendable {
    /// Direct URL to an audio stream the device can download.
    public var audioURL: URL
    public var title: String?
    public var artist: String?
    public var duration: TimeInterval?
    /// File extension to save with, e.g. `m4a`, `webm`, `opus`.
    public var fileExtension: String

    public init(
        audioURL: URL,
        title: String? = nil,
        artist: String? = nil,
        duration: TimeInterval? = nil,
        fileExtension: String = "m4a"
    ) {
        self.audioURL = audioURL
        self.title = title
        self.artist = artist
        self.duration = duration
        self.fileExtension = fileExtension
    }
}

/// Turns a YouTube link into a downloadable audio URL.
///
/// This is a protocol rather than a concrete implementation on purpose. iOS has
/// no supported API for extracting media from YouTube, and the app deliberately
/// does not embed a scraper: the extraction step is delegated to a service the
/// user configures and controls. `server/` in this repository contains a
/// reference implementation built on yt-dlp that you can run yourself.
public protocol MediaResolver: Sendable {
    func resolve(_ link: YouTubeLink) async throws -> ResolvedMedia
}

public enum MediaResolverError: LocalizedError, Equatable {
    case notConfigured
    case badResponse(statusCode: Int)
    case malformedResponse
    case unavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No resolver service is configured. Add one in Settings, "
                 + "or import an audio file from Files instead."
        case .badResponse(let statusCode):
            return "The resolver service returned an error (HTTP \(statusCode))."
        case .malformedResponse:
            return "The resolver service returned a response the app couldn't read."
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Talks to a self-hosted resolver over HTTP.
///
/// Contract — `GET {baseURL}/resolve?url={encoded youtube url}` returns:
/// ```json
/// { "audio_url": "https://…", "title": "…", "artist": "…",
///   "duration": 213.4, "ext": "m4a" }
/// ```
/// A non-2xx response with a JSON body of `{"error": "…"}` surfaces that
/// message to the user verbatim.
public struct HTTPMediaResolver: MediaResolver {
    public let baseURL: URL
    /// Optional bearer token, for a resolver you've put behind auth.
    public let accessToken: String?
    private let session: URLSession

    public init(baseURL: URL, accessToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.session = session
    }

    public func resolve(_ link: YouTubeLink) async throws -> ResolvedMedia {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("resolve"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "url", value: link.canonicalURL.absoluteString)]
        guard let url = components?.url else { throw MediaResolverError.notConfigured }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MediaResolverError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data),
               let message = payload.error {
                throw MediaResolverError.unavailable(reason: message)
            }
            throw MediaResolverError.badResponse(statusCode: http.statusCode)
        }

        let payload: ResolvePayload
        do {
            payload = try JSONDecoder().decode(ResolvePayload.self, from: data)
        } catch {
            throw MediaResolverError.malformedResponse
        }

        // Allow the service to return a path relative to itself, so it can
        // proxy the stream instead of handing out a signed CDN URL.
        let audioURL: URL?
        if payload.audioURL.hasPrefix("http://") || payload.audioURL.hasPrefix("https://") {
            audioURL = URL(string: payload.audioURL)
        } else {
            audioURL = URL(string: payload.audioURL, relativeTo: baseURL)?.absoluteURL
        }
        guard let audioURL else { throw MediaResolverError.malformedResponse }

        return ResolvedMedia(
            audioURL: audioURL,
            title: payload.title,
            artist: payload.artist,
            duration: payload.duration,
            fileExtension: payload.ext ?? "m4a"
        )
    }

    private struct ResolvePayload: Decodable {
        let audioURL: String
        let title: String?
        let artist: String?
        let duration: TimeInterval?
        let ext: String?

        enum CodingKeys: String, CodingKey {
            case audioURL = "audio_url"
            case title, artist, duration, ext
        }
    }

    private struct ErrorPayload: Decodable {
        let error: String?
    }
}
