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

    /// Set when the loaded track is mono, which the separator can only
    /// approximate. Surfaced in the player so the result isn't a mystery.
    private(set) var isMonoSource = false

    private let preparer: TrackPreparer
    private var preparationTask: Task<Void, Never>?

    init(storage: LibraryStorage) {
        self.library = KaraokeLibrary(storage: storage)
        self.preparer = TrackPreparer(storage: storage)
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

    func addYouTubeLink(_ input: String) async {
        do {
            let track = try await library.addYouTubeLink(input)
            await open(track)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFile(at url: URL) async {
        do {
            let track = try await library.addLocalFile(at: url)
            await open(track)
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
    }

    // MARK: - Playback

    /// Selects a track, separates it if needed, and loads it into the player.
    func open(_ track: Track) async {
        preparationTask?.cancel()
        player.stop()
        selectedTrackID = track.id
        isMonoSource = false

        guard track.isDownloaded else {
            preparation = nil
            return
        }

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
