import Foundation
import Observation
import SwiftUI
import KaraokeKit

/// Everything the views bind to: the library, the player, and the state of the
/// currently-loading track.
@MainActor
@Observable
final class AppModel {
    let library: KaraokeLibrary
    let player = KaraokePlayer()

    private(set) var selectedTrackID: UUID?
    private(set) var preparation: TrackPreparer.Stage?
    private(set) var errorMessage: String?

    /// The running order. Both playback paths advance through this same queue,
    /// so a karaoke video can be followed by a vocal-removed track and back.
    private(set) var queue = PlaybackQueue()
    var isShowingQueue = false

    /// Set when the loaded track is mono, which the separator can only
    /// approximate. Surfaced in the player so the result isn't a mystery.
    private(set) var isMonoSource = false

    private let preparer: TrackPreparer
    private var preparationTask: Task<Void, Never>?

    init(storage: LibraryStorage) {
        self.library = KaraokeLibrary(storage: storage)
        self.preparer = TrackPreparer(storage: storage)
        // The embedded player reports the end of a video through its JS bridge;
        // this is the same signal from the local engine.
        player.onPlaybackFinished = { [weak self] in
            self?.songFinished()
        }
    }

    var selectedTrack: Track? {
        selectedTrackID.flatMap { library.track(withID: $0) }
    }

    // MARK: - Lifecycle

    func start() {
        #if os(iOS)
        let session = AudioSessionController.shared
        do {
            try session.activate()
        } catch {
            errorMessage = "Audio couldn't be started: \(error.localizedDescription)"
        }
        session.onInterruptionBegan = { [weak self] in
            self?.player.handleInterruption()
        }
        session.onInterruptionEnded = { [weak self] shouldResume in
            if shouldResume { self?.player.play() }
        }
        session.onRouteDisconnected = { [weak self] in
            self?.player.pause()
        }
        #endif
    }

    // MARK: - Errors

    func presentError(_ message: String) {
        errorMessage = message
    }

    func dismissError() {
        errorMessage = nil
    }

    var errorBinding: Binding<Bool> {
        Binding(
            get: { self.errorMessage != nil },
            set: { if !$0 { self.errorMessage = nil } }
        )
    }

    // MARK: - Adding tracks

    /// Set when the user falls back from search to adding an original
    /// recording; carries the text they had already typed.
    var pendingOriginalQuery: String?
    var isShowingAddOriginal = false

    func presentAddOriginal(prefilling query: String = "") {
        pendingOriginalQuery = query.isEmpty ? nil : query
        isShowingAddOriginal = true
    }

    func addYouTubeLink(_ input: String) async {
        do {
            let track = try await library.addYouTubeLink(input)
            await playNow(track)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFile(at url: URL) async {
        do {
            let track = try await library.addLocalFile(at: url)
            await playNow(track)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ track: Track) {
        if selectedTrackID == track.id {
            player.stop()
            selectedTrackID = nil
            preparation = nil
        }
        library.delete(track)
        queue.prune(keeping: Set(library.tracks.map(\.id)))
    }

    // MARK: - Queue

    var upNextTracks: [Track] {
        queue.upNext.compactMap { library.track(withID: $0) }
    }

    var nextUpTrack: Track? {
        queue.nextUp.flatMap { library.track(withID: $0) }
    }

    func presentQueue() {
        isShowingQueue = true
    }

    /// Plays `track` now, keeping whatever else is queued behind it.
    func playNow(_ track: Track) async {
        queue.playNow(track.id)
        await open(track)
        startPlaybackIfLocal()
    }

    /// Starts the library at `track` and queues everything after it.
    ///
    /// What tapping a row in the sidebar does. Treating the visible list as the
    /// running order is what every music app does, and the alternative — a
    /// library of songs alongside an empty queue that says "Nothing queued" —
    /// reads as broken even though it's working as written.
    func playFromLibrary(_ track: Track) async {
        let ids = library.tracks.map(\.id)
        guard let index = ids.firstIndex(of: track.id) else {
            await playNow(track)
            return
        }
        queue.replace(with: ids, startingAt: index)
        await open(track)
        startPlaybackIfLocal()
    }

    /// Video ids for everything from the current song onward.
    var queuedVideoIDs: [String] {
        ([queue.current] + queue.upNext)
            .compactMap { $0 }
            .compactMap { library.track(withID: $0)?.source.youTubeVideoID }
    }

    /// A playlist someone shared, played instead of the local queue.
    private(set) var sharedPlaylist: YouTubePlaylist?

    func openSharedPlaylist(_ input: String) -> Bool {
        guard let playlist = YouTubePlaylist.parse(input) else { return false }
        sharedPlaylist = playlist
        return true
    }

    func clearSharedPlaylist() {
        sharedPlaylist = nil
    }

    /// Which pane the sidebar is showing.
    enum SidebarMode: String, CaseIterable, Identifiable {
        case library, find
        var id: String { rawValue }
        var title: String {
            switch self {
            case .library: return "Songs"
            case .find: return "Find"
            }
        }
    }

    var sidebarMode: SidebarMode = .library

    func playNext(_ track: Track) {
        queue.playNext(track.id)
        startIfNothingPlaying()
    }

    func addToQueue(_ track: Track) {
        queue.append(track.id)
        startIfNothingPlaying()
    }

    /// A queue with nothing playing should start as soon as something lands in
    /// it, rather than sitting silent until someone presses play.
    private func startIfNothingPlaying() {
        guard selectedTrackID == nil, let id = queue.current,
              let track = library.track(withID: id) else { return }
        Task {
            await open(track)
            startPlaybackIfLocal()
        }
    }

    func skipToNext() {
        guard let next = queue.advance(), let track = library.track(withID: next) else { return }
        Task {
            await open(track)
            startPlaybackIfLocal()
        }
    }

    func playPrevious() {
        guard let previous = queue.goBack(), let track = library.track(withID: previous) else { return }
        Task {
            await open(track)
            startPlaybackIfLocal()
        }
    }

    func jumpInQueue(to offset: Int) {
        guard let id = queue.jumpToUpNext(offset: offset),
              let track = library.track(withID: id) else { return }
        Task {
            await open(track)
            startPlaybackIfLocal()
        }
    }

    func removeFromQueue(at offsets: IndexSet) {
        queue.removeUpNext(at: offsets)
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.moveUpNext(from: source, to: destination)
    }

    func clearUpNext() {
        queue.clearUpNext()
    }

    /// Called when a song reaches its end, from either playback path.
    func songFinished() {
        guard queue.hasNext else { return }
        skipToNext()
    }

    /// Adds a video the user found by browsing YouTube.
    ///
    /// The browser is a discovery surface as much as a player, so whatever is
    /// on screen can go into the queue without a round trip through search.
    func queueBrowsedVideo(videoID: String, title: String?, playNow: Bool) {
        let cleanedTitle = Self.cleanYouTubePageTitle(title) ?? "YouTube video"
        let result = KaraokeSearchResult(
            videoID: videoID,
            title: cleanedTitle,
            channel: "",
            duration: nil,
            thumbnailURL: YouTubeLink(videoID: videoID).thumbnailURL,
            confidence: .low
        )
        let track = library.addKaraokeVideo(result)
        if playNow {
            Task { await self.playNow(track) }
        } else {
            addToQueue(track)
        }
    }

    /// A watch page's document title is "Song name - YouTube"; the suffix is
    /// noise in a library list.
    static func cleanYouTubePageTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        for suffix in [" - YouTube", " – YouTube", " — YouTube"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
            break
        }
        // A watch page shows an unread badge like "(3) Song - YouTube".
        if title.hasPrefix("("), let close = title.firstIndex(of: ")"),
           title[title.index(after: title.startIndex)..<close].allSatisfy(\.isNumber) {
            title = String(title[title.index(after: close)...])
        }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Karaoke videos autoplay themselves; the local engine needs telling.
    private func startPlaybackIfLocal() {
        guard let track = selectedTrack, !track.source.playsInEmbeddedPlayer else { return }
        guard player.state == .ready || player.state == .paused else { return }
        player.play()
    }

    // MARK: - Playback

    /// Selects a track and gets it ready to play.
    ///
    /// Karaoke videos need nothing done to them — they stream in the embedded
    /// player untouched — so this returns immediately for those. Only the
    /// fallback path pays for decoding and separation.
    func open(_ track: Track) async {
        preparationTask?.cancel()
        player.stop()
        selectedTrackID = track.id
        isMonoSource = false
        preparation = nil

        guard !track.source.playsInEmbeddedPlayer else { return }
        guard track.isDownloaded else { return }

        let settings = track.preset.settings
        preparation = .decoding

        // Awaited below rather than fired and forgotten, so callers like
        // `applyPreset` can rely on the player being loaded when this returns.
        let task = Task { [preparer] in
            do {
                let stems = try await Task.detached(priority: .userInitiated) {
                    try await preparer.prepare(track: track, settings: settings) { stage in
                        Task { @MainActor in
                            // Ignore updates from a run the user has moved on from.
                            guard self.selectedTrackID == track.id else { return }
                            self.preparation = stage
                        }
                    }
                }.value

                guard !Task.isCancelled, selectedTrackID == track.id else { return }

                isMonoSource = stems.usedMonoFallback
                try player.load(vocal: stems.vocal, instrumental: stems.instrumental)
                player.vocalLevel = track.vocalLevel
                player.pitchSemitones = track.pitchSemitones
                preparation = nil
            } catch is CancellationError {
                preparation = nil
            } catch {
                guard selectedTrackID == track.id else { return }
                preparation = nil
                errorMessage = error.localizedDescription
            }
        }
        preparationTask = task
        await task.value
    }

    /// Re-runs separation with a different preset, keeping the playhead.
    func applyPreset(_ preset: SeparationSettings.Preset) async {
        guard var track = selectedTrack, track.preset != preset else { return }
        let resumeAt = player.currentTime
        let wasPlaying = player.state == .playing

        track.preset = preset
        library.update(track)

        await open(track)
        guard selectedTrackID == track.id, player.state != .idle else { return }
        player.seek(to: resumeAt)
        if wasPlaying { player.play() }
    }

    /// Persists fader positions so a track reopens the way it was left.
    func persistPlayerSettings() {
        guard var track = selectedTrack else { return }
        track.vocalLevel = player.vocalLevel
        track.pitchSemitones = player.pitchSemitones
        library.update(track)
    }
}
