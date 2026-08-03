import Foundation

/// Where a track's audio came from.
public enum TrackSource: Equatable, Hashable, Codable, Sendable {
    /// Resolved from a YouTube link via the configured resolver service.
    case youTube(videoID: String)
    /// Imported from the Files app, AirDrop, or another app's share sheet.
    case importedFile(originalName: String)

    public var youTubeVideoID: String? {
        if case .youTube(let id) = self { return id }
        return nil
    }
}

/// A song in the user's library.
public struct Track: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var artist: String?
    public var source: TrackSource
    /// File name (not path) of the source audio inside the media directory.
    /// `nil` until the audio has been downloaded or copied in.
    public var mediaFileName: String?
    public var duration: TimeInterval?
    public var artworkURL: URL?
    public var dateAdded: Date
    /// Separation preset the user last used for this track.
    public var preset: SeparationSettings.Preset
    /// Vocal fader position the user last left this track at, 0...1.
    public var vocalLevel: Float
    /// Key change in semitones the user last used.
    public var pitchSemitones: Float

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String? = nil,
        source: TrackSource,
        mediaFileName: String? = nil,
        duration: TimeInterval? = nil,
        artworkURL: URL? = nil,
        dateAdded: Date = Date(),
        preset: SeparationSettings.Preset = .balanced,
        vocalLevel: Float = 0,
        pitchSemitones: Float = 0
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.source = source
        self.mediaFileName = mediaFileName
        self.duration = duration
        self.artworkURL = artworkURL
        self.dateAdded = dateAdded
        self.preset = preset
        self.vocalLevel = vocalLevel
        self.pitchSemitones = pitchSemitones
    }

    /// True once the audio is on disk and the track can be played offline.
    public var isDownloaded: Bool { mediaFileName != nil }

    public var subtitle: String {
        artist ?? {
            switch source {
            case .youTube: return "YouTube"
            case .importedFile: return "Imported"
            }
        }()
    }
}
