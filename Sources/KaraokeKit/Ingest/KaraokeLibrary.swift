import Foundation
import Observation

#if canImport(AVFoundation)
import AVFoundation

/// The app's library: the track list plus the operations that add to it.
@MainActor
@Observable
public final class KaraokeLibrary {
    public private(set) var tracks: [Track] = []
    /// Per-track import progress, keyed by track id.
    public private(set) var importProgress: [UUID: TrackPreparer.Stage] = [:]
    /// Computed over tracked storage: `@Observable` rewrites stored properties
    /// into computed ones, so it can't take a `didSet` to persist on change.
    public var resolverConfiguration: ResolverConfiguration {
        get { storedResolverConfiguration }
        set {
            storedResolverConfiguration = newValue
            newValue.save()
        }
    }

    private var storedResolverConfiguration: ResolverConfiguration

    public let storage: LibraryStorage
    private let downloader = MediaDownloader()
    private let metadataService = YouTubeMetadataService()

    public init(storage: LibraryStorage) {
        self.storage = storage
        self.storedResolverConfiguration = .load()
        self.tracks = storage.loadTracks().sorted { $0.dateAdded > $1.dateAdded }
    }

    public convenience init() throws {
        self.init(storage: try LibraryStorage.default())
    }

    // MARK: - Mutation

    public func track(withID id: UUID) -> Track? {
        tracks.first { $0.id == id }
    }

    public func update(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index] = track
        persist()
    }

    public func delete(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        importProgress[track.id] = nil
        storage.removeFiles(for: track)
        persist()
    }

    private func persist() {
        try? storage.saveTracks(tracks)
    }

    private func setStage(_ stage: TrackPreparer.Stage?, for id: UUID) {
        importProgress[id] = stage
    }

    // MARK: - Karaoke videos

    /// Searches for karaoke versions of a song.
    public func searchKaraoke(_ query: String) async throws -> [KaraokeSearchResult] {
        guard let client = resolverConfiguration.makeSearchClient() else {
            throw KaraokeSearchError.notConfigured
        }
        return try await client.search(query)
    }

    /// Adds a karaoke video to the library.
    ///
    /// Nothing is downloaded and nothing is analysed — the video streams from
    /// YouTube in the embedded player — so this is immediate.
    @discardableResult
    public func addKaraokeVideo(_ result: KaraokeSearchResult) -> Track {
        if let existing = tracks.first(where: {
            $0.source == .karaokeVideo(videoID: result.videoID)
        }) {
            return existing
        }

        let track = Track(
            title: result.title,
            artist: result.channel.isEmpty ? nil : result.channel,
            source: .karaokeVideo(videoID: result.videoID),
            duration: result.duration,
            artworkURL: result.thumbnailURL ?? result.link.thumbnailURL
        )
        tracks.insert(track, at: 0)
        persist()
        return track
    }

    // MARK: - Adding from YouTube

    public enum AddError: LocalizedError {
        case notAYouTubeLink
        case alreadyInLibrary(Track)
        case noResolver

        public var errorDescription: String? {
            switch self {
            case .notAYouTubeLink:
                return "That doesn't look like a YouTube link."
            case .alreadyInLibrary(let track):
                return "\"\(track.title)\" is already in your library."
            case .noResolver:
                return MediaResolverError.notConfigured.errorDescription
            }
        }
    }

    /// Adds a YouTube link: fetches its title, downloads the audio, and leaves
    /// the track ready to open. Separation happens lazily on first play.
    ///
    /// - Returns: the newly added track.
    @discardableResult
    public func addYouTubeLink(_ input: String) async throws -> Track {
        guard let link = YouTubeLink.parse(input) else {
            throw AddError.notAYouTubeLink
        }
        if let existing = tracks.first(where: { $0.source.youTubeVideoID == link.videoID }) {
            throw AddError.alreadyInLibrary(existing)
        }
        guard let resolver = resolverConfiguration.makeResolver() else {
            throw AddError.noResolver
        }

        // Insert a placeholder immediately so the row appears with a spinner
        // rather than the UI sitting silent through a network round trip.
        var track = Track(
            title: "Loading…",
            source: .youTube(videoID: link.videoID),
            artworkURL: link.thumbnailURL
        )
        tracks.insert(track, at: 0)
        setStage(.resolving, for: track.id)

        do {
            if let metadata = await metadataService.metadata(for: link) {
                track.title = metadata.title
                track.artist = metadata.author
                if let thumbnail = metadata.thumbnailURL { track.artworkURL = thumbnail }
                replaceInPlace(track)
            }

            let media = try await resolver.resolve(link)
            if let title = media.title, track.title == "Loading…" || track.title.isEmpty {
                track.title = title
            }
            if track.artist == nil { track.artist = media.artist }
            track.duration = media.duration
            replaceInPlace(track)

            let fileName = "\(track.id.uuidString).\(media.fileExtension)"
            let destination = storage.mediaURL(for: fileName)

            setStage(.downloading(progress: 0), for: track.id)
            let trackID = track.id
            try await downloader.download(media, to: destination) { [weak self] fraction in
                Task { @MainActor in
                    self?.setStage(.downloading(progress: fraction), for: trackID)
                }
            }

            track.mediaFileName = fileName
            if track.title == "Loading…" { track.title = link.videoID }
            replaceInPlace(track)
            setStage(nil, for: track.id)
            persist()
            return track
        } catch {
            tracks.removeAll { $0.id == track.id }
            setStage(nil, for: track.id)
            throw error
        }
    }

    /// Adds an audio or video file the user picked from Files.
    @discardableResult
    public func addLocalFile(at url: URL) async throws -> Track {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let originalName = url.lastPathComponent
        var track = Track(
            title: url.deletingPathExtension().lastPathComponent,
            source: .importedFile(originalName: originalName)
        )

        let fileExtension = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let fileName = "\(track.id.uuidString).\(fileExtension)"
        let destination = storage.mediaURL(for: fileName)
        try downloader.copyLocalFile(at: url, to: destination)

        track.mediaFileName = fileName
        if let signal = try? AudioSignal.decode(contentsOf: destination) {
            track.duration = signal.duration
        }

        tracks.insert(track, at: 0)
        persist()
        return track
    }

    private func replaceInPlace(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index] = track
    }

    // MARK: - Housekeeping

    public func diskUsageDescription() -> String {
        let bytes = storage.diskUsage()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Drops every cached separation result, keeping the downloaded audio.
    public func clearSeparationCache() {
        StemCache(directory: storage.stemsDirectory).removeAll()
    }
}
#endif
