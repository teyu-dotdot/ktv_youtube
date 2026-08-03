import Foundation

#if canImport(AVFoundation)
import AVFoundation

/// Turns a library track into a pair of ready-to-play stems.
///
/// Separation is the expensive step — a few seconds of arithmetic for a
/// four-minute song — so results go through ``StemCache`` and are only
/// recomputed when the track or its preset changes.
public struct TrackPreparer: Sendable {
    /// Coarse phases, so the UI can say what it's waiting on rather than just
    /// showing an indeterminate spinner.
    public enum Stage: Equatable, Sendable {
        case resolving
        case downloading(progress: Double?)
        case decoding
        case separating(progress: Double)
        case ready

        public var message: String {
            switch self {
            case .resolving: return "Finding the audio…"
            case .downloading: return "Downloading…"
            case .decoding: return "Reading the audio…"
            case .separating: return "Removing vocals…"
            case .ready: return "Ready"
            }
        }

        /// 0...1 where known, nil while indeterminate.
        public var fraction: Double? {
            switch self {
            case .resolving: return nil
            case .downloading(let progress): return progress
            case .decoding: return nil
            case .separating(let progress): return progress
            case .ready: return 1
            }
        }
    }

    public struct Stems: Sendable {
        public var vocal: AudioSignal
        public var instrumental: AudioSignal
        /// True when the source had no usable stereo image, so the result came
        /// from the weak mono approximation rather than centre extraction.
        public var usedMonoFallback: Bool
        public var duration: TimeInterval { vocal.duration }
    }

    private let storage: LibraryStorage
    private let cache: StemCache

    public init(storage: LibraryStorage) {
        self.storage = storage
        self.cache = StemCache(directory: storage.stemsDirectory)
    }

    /// Prepares `track`, which must already have its media downloaded.
    ///
    /// Runs off the main actor; `onStage` is invoked from a background context,
    /// so hop to the main actor before touching UI state.
    public func prepare(
        track: Track,
        settings: SeparationSettings,
        onStage: (@Sendable (Stage) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> Stems {
        guard let fileName = track.mediaFileName else {
            throw PreparationError.mediaMissing
        }
        let mediaURL = storage.mediaURL(for: fileName)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw PreparationError.mediaMissing
        }

        onStage?(.decoding)
        let original = try AudioSignal.decode(contentsOf: mediaURL)
        try Task.checkCancellation()
        let usedMonoFallback = VocalSeparator.usesMonoFallback(for: original)

        // Cache hit: rebuild the instrumental by subtraction, which is exactly
        // what the separator would have produced.
        if let cachedVocal = cache.loadVocalStem(trackID: track.id, settings: settings),
           cachedVocal.frameCount == original.frameCount,
           cachedVocal.channelCount == original.channelCount {
            onStage?(.ready)
            return Stems(
                vocal: cachedVocal,
                instrumental: Self.subtract(cachedVocal, from: original),
                usedMonoFallback: usedMonoFallback
            )
        }

        onStage?(.separating(progress: 0))
        let separator = VocalSeparator(settings: settings)
        let result = try separator.separate(
            original,
            progress: { onStage?(.separating(progress: $0)) },
            isCancelled: { isCancelled?() == true || Task.isCancelled }
        )
        try Task.checkCancellation()

        // A cache write failure is not worth failing playback over.
        try? cache.store(vocalStem: result.vocal, trackID: track.id, settings: settings)

        onStage?(.ready)
        return Stems(
            vocal: result.vocal,
            instrumental: result.instrumental,
            usedMonoFallback: usedMonoFallback
        )
    }

    static func subtract(_ stem: AudioSignal, from original: AudioSignal) -> AudioSignal {
        var channels = original.channels
        for channel in channels.indices where channel < stem.channelCount {
            for index in channels[channel].indices {
                channels[channel][index] -= stem.channels[channel][index]
            }
        }
        return AudioSignal(channels: channels, sampleRate: original.sampleRate)
    }

    public enum PreparationError: LocalizedError {
        case mediaMissing

        public var errorDescription: String? {
            switch self {
            case .mediaMissing:
                return "This track's audio isn't on the device. Try adding it again."
            }
        }
    }
}
#endif
