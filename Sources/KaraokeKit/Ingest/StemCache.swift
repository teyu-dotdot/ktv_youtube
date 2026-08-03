import Foundation

#if canImport(AVFoundation)
import AVFoundation

/// Caches separation results so a track only pays the analysis cost once.
///
/// Only the **vocal** stem is stored. The instrumental is `original - vocal`, so
/// keeping the vocal stem alongside the (already-on-disk, compressed) source is
/// enough to rebuild both stems exactly — half the disk of caching both, and it
/// preserves the exact-sum property the player depends on.
///
/// Entries are keyed by track id *and* a fingerprint of the separation
/// settings, so changing the preset produces a new entry rather than silently
/// serving a stale one.
public struct StemCache: Sendable {
    public let directory: URL
    /// Cache ceiling in bytes. Oldest entries are evicted past this.
    public let budgetBytes: Int64

    public init(directory: URL, budgetBytes: Int64 = 2_000_000_000) {
        self.directory = directory
        self.budgetBytes = budgetBytes
    }

    /// Float32 CAF: lossless, so `original - vocal` stays sample-exact.
    private static let fileExtension = "caf"

    func url(trackID: UUID, settings: SeparationSettings) -> URL {
        let name = "\(trackID.uuidString)-\(Self.fingerprint(of: settings)).\(Self.fileExtension)"
        return directory.appendingPathComponent(name)
    }

    /// Short, stable hash of every setting that changes the output.
    static func fingerprint(of settings: SeparationSettings) -> String {
        var hasher = Hasher()
        hasher.combine(settings.fftSize)
        hasher.combine(settings.similarityExponent)
        hasher.combine(settings.balanceExponent)
        hasher.combine(settings.lowCutHz)
        hasher.combine(settings.highCutHz)
        hasher.combine(settings.strength)
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }

    /// Returns the cached vocal stem, or nil on a miss.
    public func loadVocalStem(trackID: UUID, settings: SeparationSettings) -> AudioSignal? {
        let fileURL = url(trackID: trackID, settings: settings)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let signal = try? AudioSignal.decode(contentsOf: fileURL) else {
            // A truncated file from an interrupted write — drop it.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        touch(fileURL)
        return signal
    }

    /// Writes the vocal stem, then trims the cache back under budget.
    public func store(vocalStem: AudioSignal, trackID: UUID, settings: SeparationSettings) throws {
        let fileURL = url(trackID: trackID, settings: settings)
        guard let buffer = vocalStem.makeBuffer() else { return }

        // Write to a temporary name first so an interrupted write can't leave a
        // half-file that later reads as a cache hit.
        let temporaryURL = fileURL.appendingPathExtension("partial")
        var fileSettings = buffer.format.settings
        fileSettings[AVFormatIDKey] = kAudioFormatLinearPCM
        fileSettings[AVLinearPCMIsFloatKey] = true
        fileSettings[AVLinearPCMBitDepthKey] = 32
        fileSettings[AVLinearPCMIsNonInterleaved] = false

        let file = try AVAudioFile(
            forWriting: temporaryURL,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)

        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        evictIfNeeded()
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
    }

    /// Least-recently-used eviction down to the budget.
    func evictIfNeeded() {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var entries = contents.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ), let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > budgetBytes else { return }

        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > budgetBytes {
            try? manager.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    /// Drops every cached stem.
    public func removeAll() {
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try? manager.removeItem(at: url)
        }
    }
}
#endif
