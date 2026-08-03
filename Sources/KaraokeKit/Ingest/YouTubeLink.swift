import Foundation

/// A parsed YouTube video reference.
public struct YouTubeLink: Equatable, Hashable, Codable, Sendable {
    /// The 11-character video id.
    public let videoID: String
    /// Start offset encoded in the link (`?t=90`, `#t=1m30s`), if any.
    public let startTime: TimeInterval?

    public init(videoID: String, startTime: TimeInterval? = nil) {
        self.videoID = videoID
        self.startTime = startTime
    }

    /// Canonical watch URL for this video.
    public var canonicalURL: URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
    }

    /// Default thumbnail. `hqdefault` exists for every video; the higher
    /// resolutions do not, so this is the safe one to request.
    public var thumbnailURL: URL {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!
    }

    /// Parses the URL and short-link forms YouTube hands out, plus a bare id.
    ///
    /// Handles `youtube.com/watch?v=`, `youtu.be/`, `/embed/`, `/shorts/`,
    /// `/live/`, `/v/`, `music.youtube.com`, and any of those with extra query
    /// parameters, a playlist, or a timestamp attached.
    public static func parse(_ input: String) -> YouTubeLink? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A bare video id pasted on its own.
        if isValidVideoID(trimmed) {
            return YouTubeLink(videoID: trimmed)
        }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
              let host = components.host?.lowercased() else { return nil }

        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let isYouTubeHost = bareHost == "youtube.com"
            || bareHost == "m.youtube.com"
            || bareHost == "music.youtube.com"
            || bareHost == "youtube-nocookie.com"
        let isShortHost = bareHost == "youtu.be"
        guard isYouTubeHost || isShortHost else { return nil }

        let queryItems = components.queryItems ?? []
        let start = startTime(from: queryItems, fragment: components.fragment)
        let pathSegments = components.path.split(separator: "/").map(String.init)

        if isShortHost {
            guard let id = pathSegments.first, isValidVideoID(id) else { return nil }
            return YouTubeLink(videoID: id, startTime: start)
        }

        if let value = queryItems.first(where: { $0.name == "v" })?.value,
           isValidVideoID(value) {
            return YouTubeLink(videoID: value, startTime: start)
        }

        // /embed/ID, /shorts/ID, /live/ID, /v/ID
        let idBearingPrefixes: Set<String> = ["embed", "shorts", "live", "v"]
        if pathSegments.count >= 2,
           idBearingPrefixes.contains(pathSegments[0]),
           isValidVideoID(pathSegments[1]) {
            return YouTubeLink(videoID: pathSegments[1], startTime: start)
        }

        return nil
    }

    /// YouTube ids are exactly 11 characters of base64url.
    static func isValidVideoID(_ candidate: String) -> Bool {
        guard candidate.count == 11 else { return false }
        return candidate.allSatisfy { character in
            character.isLetter && character.isASCII
                || character.isNumber && character.isASCII
                || character == "-" || character == "_"
        }
    }

    private static func startTime(from queryItems: [URLQueryItem], fragment: String?) -> TimeInterval? {
        if let raw = queryItems.first(where: { $0.name == "t" || $0.name == "start" })?.value,
           let seconds = parseDuration(raw) {
            return seconds
        }
        if let fragment, fragment.hasPrefix("t=") {
            return parseDuration(String(fragment.dropFirst(2)))
        }
        return nil
    }

    /// Accepts `90`, `90s`, `1m30s`, `1h2m3s`.
    static func parseDuration(_ raw: String) -> TimeInterval? {
        if let plain = TimeInterval(raw) { return plain >= 0 ? plain : nil }

        var total: TimeInterval = 0
        var number = ""
        var sawUnit = false
        for character in raw.lowercased() {
            if character.isNumber {
                number.append(character)
                continue
            }
            guard let value = TimeInterval(number) else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            sawUnit = true
            number = ""
        }
        if !number.isEmpty, let value = TimeInterval(number) {
            total += value
            sawUnit = true
        }
        return sawUnit ? total : nil
    }
}
