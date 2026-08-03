import Foundation

/// User-configured location of the resolver service.
///
/// Stored in `UserDefaults` rather than compiled in: every user points the app
/// at their own instance, and there is no default endpoint.
public struct ResolverConfiguration: Equatable, Sendable {
    public var baseURLString: String
    public var accessToken: String

    /// A YouTube Data API key, which lets the app search on its own with no
    /// helper service at all. Optional, and independent of the service above:
    /// with just this, the karaoke half of the app works and the
    /// vocal-removal fallback doesn't.
    public var youTubeAPIKey: String

    /// A YouTube playlist everyone at the party adds to. Persisted so the room
    /// doesn't have to re-paste the link every time the app opens.
    public var sharedPlaylistID: String

    public init(
        baseURLString: String = "",
        accessToken: String = "",
        youTubeAPIKey: String = "",
        sharedPlaylistID: String = ""
    ) {
        self.baseURLString = baseURLString
        self.accessToken = accessToken
        self.youTubeAPIKey = youTubeAPIKey
        self.sharedPlaylistID = sharedPlaylistID
    }

    public var sharedPlaylist: YouTubePlaylist? {
        let trimmed = sharedPlaylistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return YouTubePlaylist(listID: trimmed)
    }

    public var baseURL: URL? {
        var trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a trailing slash so "http://mac.local:8808/" works. Done on
        // the string rather than via `deleteLastPathComponent`, which leaves the
        // root slash in place and would produce a double slash when appending.
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }

        // A bare host means the user typed "resolver.example.com"; default to
        // HTTPS, but never rewrite a scheme they gave us explicitly.
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }

    /// True when the helper service is set up, which the vocal-removal
    /// fallback needs.
    public var isConfigured: Bool { baseURL != nil }

    /// True when songs can be searched for, by either route.
    public var canSearch: Bool {
        !youTubeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL != nil
    }

    /// Builds a resolver, or nil when nothing is configured yet.
    public func makeResolver(session: URLSession = .shared) -> MediaResolver? {
        guard let baseURL else { return nil }
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return HTTPMediaResolver(
            baseURL: baseURL,
            accessToken: token.isEmpty ? nil : token,
            session: session
        )
    }

    // MARK: - Persistence

    private static let baseURLKey = "resolver.baseURL"
    private static let tokenKey = "resolver.accessToken"
    private static let apiKeyKey = "search.youTubeAPIKey"
    private static let playlistKey = "party.sharedPlaylistID"

    public static func load(from defaults: UserDefaults = .standard) -> ResolverConfiguration {
        ResolverConfiguration(
            baseURLString: defaults.string(forKey: baseURLKey) ?? "",
            accessToken: defaults.string(forKey: tokenKey) ?? "",
            youTubeAPIKey: defaults.string(forKey: apiKeyKey) ?? "",
            sharedPlaylistID: defaults.string(forKey: playlistKey) ?? ""
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(baseURLString, forKey: Self.baseURLKey)
        defaults.set(accessToken, forKey: Self.tokenKey)
        defaults.set(youTubeAPIKey, forKey: Self.apiKeyKey)
        defaults.set(sharedPlaylistID, forKey: Self.playlistKey)
    }
}
