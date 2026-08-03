import Foundation

/// A reference to a YouTube playlist, and the URLs that hand a running order
/// over to YouTube itself.
///
/// Two ways to make YouTube own the queue rather than fight it:
///
/// * **An anonymous playlist.** `watch_videos?video_ids=a,b,c` builds a
///   throwaway playlist out of a list of ids, with no account and no API call.
///   YouTube then advances through it natively, which is more reliable than
///   racing its autoplay, and its own sidebar shows that running order instead
///   of unrelated suggestions.
/// * **A real playlist.** `watch?list=…` plays one someone owns. If it's marked
///   collaborative, other people can add to it from their own phones, which is
///   the only way to get a shared queue without running a server.
public struct YouTubePlaylist: Equatable, Hashable, Codable, Sendable {
    public let listID: String

    public init(listID: String) {
        self.listID = listID
    }

    /// Watch URL that starts the playlist from the top.
    public var watchURL: URL {
        URL(string: "https://www.youtube.com/watch?list=\(listID)&playnext=1")!
    }

    /// The playlist's own page, for sharing or editing.
    public var pageURL: URL {
        URL(string: "https://www.youtube.com/playlist?list=\(listID)")!
    }

    /// Playlist ids are prefixed by kind: PL user-made, UU channel uploads,
    /// LL liked, RD radio, OL/FL legacy. Anything else isn't one.
    static let knownPrefixes = ["PL", "UU", "LL", "RD", "OL", "FL", "TL"]

    public static func isValidListID(_ candidate: String) -> Bool {
        guard candidate.count >= 12, candidate.count <= 42 else { return false }
        guard knownPrefixes.contains(where: { candidate.hasPrefix($0) }) else { return false }
        return candidate.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber
                                  || character == "-" || character == "_")
        }
    }

    /// Accepts a playlist URL, a watch URL carrying `list=`, or a bare id.
    public static func parse(_ input: String) -> YouTubePlaylist? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isValidListID(trimmed) {
            return YouTubePlaylist(listID: trimmed)
        }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
              let host = components.host?.lowercased() else { return nil }

        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let allowed: Set<String> = [
            "youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"
        ]
        guard allowed.contains(bareHost) else { return nil }

        guard let value = components.queryItems?.first(where: { $0.name == "list" })?.value,
              isValidListID(value) else { return nil }
        return YouTubePlaylist(listID: value)
    }

    /// Builds a throwaway playlist from a running order.
    ///
    /// - Parameter videoIDs: in play order. YouTube caps the URL well before
    ///   this matters in practice, so the list is trimmed to `limit`.
    /// - Returns: nil when there's nothing to play.
    public static func anonymousPlaylistURL(
        videoIDs: [String],
        limit: Int = 50
    ) -> URL? {
        let valid = videoIDs.filter(YouTubeLink.isValidVideoID).prefix(limit)
        guard !valid.isEmpty else { return nil }
        return URL(string: "https://www.youtube.com/watch_videos?video_ids=\(valid.joined(separator: ","))")
    }
}
