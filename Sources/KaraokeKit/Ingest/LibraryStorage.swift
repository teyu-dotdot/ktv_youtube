import Foundation

/// Owns the on-disk layout: the library index, downloaded source audio, and the
/// stem cache.
///
///     <Application Support>/KTVYouTube/
///       library.json          the track index
///       Media/                downloaded / imported source audio
///       Stems/                cached vocal stems (see StemCache)
public struct LibraryStorage: Sendable {
    public let rootDirectory: URL

    public var mediaDirectory: URL { rootDirectory.appendingPathComponent("Media", isDirectory: true) }
    public var stemsDirectory: URL { rootDirectory.appendingPathComponent("Stems", isDirectory: true) }
    public var indexURL: URL { rootDirectory.appendingPathComponent("library.json") }

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// The default location under Application Support.
    public static func `default`() throws -> LibraryStorage {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storage = LibraryStorage(
            rootDirectory: base.appendingPathComponent("KTVYouTube", isDirectory: true)
        )
        try storage.createDirectories()
        return storage
    }

    public func createDirectories() throws {
        let manager = FileManager.default
        for directory in [rootDirectory, mediaDirectory, stemsDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Downloaded audio is re-downloadable and the stem cache is derived, so
        // neither belongs in the user's iCloud backup.
        try excludeFromBackup(mediaDirectory)
        try excludeFromBackup(stemsDirectory)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    public func mediaURL(for fileName: String) -> URL {
        mediaDirectory.appendingPathComponent(fileName)
    }

    // MARK: - Index

    public func loadTracks() -> [Track] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Track].self, from: data)) ?? []
    }

    public func saveTracks(_ tracks: [Track]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tracks)
        try data.write(to: indexURL, options: .atomic)
    }

    /// Deletes the source audio and any cached stems for a track.
    public func removeFiles(for track: Track) {
        let manager = FileManager.default
        if let fileName = track.mediaFileName {
            try? manager.removeItem(at: mediaURL(for: fileName))
        }
        let prefix = track.id.uuidString
        let contents = (try? manager.contentsOfDirectory(
            at: stemsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(prefix) {
            try? manager.removeItem(at: url)
        }
    }

    /// Total bytes used by downloaded audio and cached stems.
    public func diskUsage() -> Int64 {
        [mediaDirectory, stemsDirectory].reduce(Int64(0)) { total, directory in
            total + Self.directorySize(directory)
        }
    }

    static func directorySize(_ directory: URL) -> Int64 {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}
