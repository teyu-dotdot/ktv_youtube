import Foundation
import Observation

#if canImport(AVFoundation)
import AVFoundation

/// Two-stem karaoke transport.
///
/// The separator gives us a vocal stem and an instrumental stem that sum back
/// to the original recording. Rather than re-running any DSP when the user
/// moves the vocal fader, this schedules both stems on their own player nodes
/// and changes the vocal node's gain. Consequences worth knowing:
///
/// * Moving the fader is free and click-free — it's a mixer gain, not a
///   re-render, so it can be automated during playback.
/// * At vocal level 1.0 the output is the original recording sample-for-sample,
///   because the stems sum exactly.
/// * Both nodes are started against one shared `AVAudioTime`, so they stay
///   sample-locked rather than drifting by a buffer.
@MainActor
@Observable
public final class KaraokePlayer {
    public enum State: Equatable, Sendable {
        case idle
        case ready
        case playing
        case paused
    }

    // MARK: Observable state

    public private(set) var state: State = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    // These are computed over tracked storage rather than plain stored
    // properties with `didSet`, because the `@Observable` macro rewrites stored
    // properties into computed ones and so can't accept property observers.

    /// How much of the original vocal to mix back in, 0...1.
    /// `0` is full karaoke, `1` is the untouched recording.
    public var vocalLevel: Float {
        get { storedVocalLevel }
        set {
            storedVocalLevel = max(0, min(1, newValue))
            vocalPlayer.volume = storedVocalLevel
        }
    }

    /// Key change in semitones, -12...12. Applied to both stems together.
    public var pitchSemitones: Float {
        get { storedPitchSemitones }
        set {
            storedPitchSemitones = max(-12, min(12, newValue))
            timePitch.pitch = storedPitchSemitones * 100
        }
    }

    /// Playback rate, 0.5...2.0, without changing pitch.
    public var tempo: Float {
        get { storedTempo }
        set {
            storedTempo = max(0.5, min(2.0, newValue))
            timePitch.rate = storedTempo
        }
    }

    /// Output gain, 0...1.
    public var volume: Float {
        get { storedVolume }
        set {
            storedVolume = max(0, min(1, newValue))
            engine.mainMixerNode.outputVolume = storedVolume
        }
    }

    private var storedVocalLevel: Float = 0
    private var storedPitchSemitones: Float = 0
    private var storedTempo: Float = 1
    private var storedVolume: Float = 1

    // MARK: Audio graph

    private let engine = AVAudioEngine()
    private let vocalPlayer = AVAudioPlayerNode()
    private let instrumentalPlayer = AVAudioPlayerNode()
    private let submix = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var vocalBuffer: AVAudioPCMBuffer?
    private var instrumentalBuffer: AVAudioPCMBuffer?
    private var sampleRate: Double = 44_100

    /// Frame the current scheduling run started from; playerTime is relative to it.
    private var scheduleOriginFrame: AVAudioFramePosition = 0
    private var displayLinkTimer: Timer?
    private var isSeeking = false

    /// Called when the track plays through to the end.
    public var onPlaybackFinished: (() -> Void)?

    public init() {
        engine.attach(vocalPlayer)
        engine.attach(instrumentalPlayer)
        engine.attach(submix)
        engine.attach(timePitch)
    }

    // MARK: - Loading

    /// Loads a separated pair of stems and gets the graph ready to play.
    ///
    /// - Throws: ``KaraokePlayerError`` if the stems don't line up or the
    ///   engine refuses to start.
    public func load(vocal: AudioSignal, instrumental: AudioSignal) throws {
        guard vocal.frameCount == instrumental.frameCount,
              vocal.sampleRate == instrumental.sampleRate else {
            throw KaraokePlayerError.mismatchedStems
        }
        guard let vocalBuffer = vocal.makeBuffer(),
              let instrumentalBuffer = instrumental.makeBuffer() else {
            throw KaraokePlayerError.bufferAllocationFailed
        }

        stop()

        self.vocalBuffer = vocalBuffer
        self.instrumentalBuffer = instrumentalBuffer
        self.sampleRate = vocal.sampleRate
        self.duration = vocal.duration
        self.currentTime = 0

        try connectGraph(format: vocalBuffer.format)
        try startEngineIfNeeded()

        vocalPlayer.volume = storedVocalLevel
        instrumentalPlayer.volume = 1
        schedule(fromFrame: 0)
        state = .ready
    }

    private func connectGraph(format: AVAudioFormat) throws {
        // Rebuilding is cheap and avoids format mismatches between tracks.
        engine.disconnectNodeOutput(vocalPlayer)
        engine.disconnectNodeOutput(instrumentalPlayer)
        engine.disconnectNodeOutput(submix)
        engine.disconnectNodeOutput(timePitch)

        engine.connect(vocalPlayer, to: submix, format: format)
        engine.connect(instrumentalPlayer, to: submix, format: format)
        engine.connect(submix, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        timePitch.pitch = storedPitchSemitones * 100
        timePitch.rate = storedTempo
        engine.mainMixerNode.outputVolume = storedVolume
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw KaraokePlayerError.engineFailed(underlying: error)
        }
    }

    // MARK: - Transport

    public func play() {
        guard vocalBuffer != nil, state != .playing else { return }
        do {
            try startEngineIfNeeded()
        } catch {
            return
        }

        // One shared start time so the two stems begin on the same sample.
        let lead = AVAudioTime.hostTime(forSeconds: 0.06)
        let startTime = AVAudioTime(hostTime: mach_absolute_time() + lead)
        vocalPlayer.play(at: startTime)
        instrumentalPlayer.play(at: startTime)

        state = .playing
        startPositionUpdates()
    }

    public func pause() {
        guard state == .playing else { return }
        vocalPlayer.pause()
        instrumentalPlayer.pause()
        state = .paused
        stopPositionUpdates()
    }

    public func togglePlayPause() {
        state == .playing ? pause() : play()
    }

    public func stop() {
        vocalPlayer.stop()
        instrumentalPlayer.stop()
        stopPositionUpdates()
        scheduleOriginFrame = 0
        currentTime = 0
        if vocalBuffer != nil { state = .ready }
    }

    /// Jumps to `time` seconds, keeping the two stems locked together.
    public func seek(to time: TimeInterval) {
        guard vocalBuffer != nil else { return }
        let clamped = max(0, min(duration, time))
        let wasPlaying = state == .playing

        isSeeking = true
        vocalPlayer.stop()
        instrumentalPlayer.stop()

        let frame = AVAudioFramePosition(clamped * sampleRate)
        schedule(fromFrame: frame)
        currentTime = clamped
        isSeeking = false

        if wasPlaying {
            state = .paused   // so play() doesn't early-return
            play()
        } else {
            state = .ready
        }
    }

    public func skip(by interval: TimeInterval) {
        seek(to: currentTime + interval)
    }

    // MARK: - Scheduling

    private func schedule(fromFrame frame: AVAudioFramePosition) {
        guard let vocalBuffer, let instrumentalBuffer else { return }
        let totalFrames = AVAudioFramePosition(vocalBuffer.frameLength)
        let start = max(0, min(totalFrames, frame))
        scheduleOriginFrame = start

        guard start < totalFrames else {
            handlePlaybackFinished()
            return
        }

        let remaining = AVAudioFrameCount(totalFrames - start)
        guard let vocalSlice = Self.slice(vocalBuffer, from: start, frames: remaining),
              let instrumentalSlice = Self.slice(instrumentalBuffer, from: start, frames: remaining)
        else { return }

        // Only the instrumental reports completion: the two stems are the same
        // length and start together, so one callback is enough and two would
        // fire the finish handler twice.
        vocalPlayer.scheduleBuffer(vocalSlice, at: nil, options: [])
        instrumentalPlayer.scheduleBuffer(
            instrumentalSlice, at: nil, options: [], completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSeeking, self.state == .playing else { return }
                self.handlePlaybackFinished()
            }
        }
    }

    private static func slice(
        _ buffer: AVAudioPCMBuffer,
        from start: AVAudioFramePosition,
        frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames),
              let destination = slice.floatChannelData else { return nil }

        slice.frameLength = frames
        let offset = Int(start)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + offset, count: Int(frames))
        }
        return slice
    }

    private func handlePlaybackFinished() {
        stopPositionUpdates()
        vocalPlayer.stop()
        instrumentalPlayer.stop()
        state = .ready
        schedule(fromFrame: 0)
        currentTime = 0
        onPlaybackFinished?()
    }

    // MARK: - Position

    private func startPositionUpdates() {
        stopPositionUpdates()
        // The timer invalidates itself once the player is gone, rather than
        // being torn down in `deinit`. A deinit is nonisolated, so it can't
        // touch a main-actor property, and the run loop holds the timer alive
        // regardless of what happens to us.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard self != nil else {
                timer.invalidate()
                return
            }
            Task { @MainActor in self?.updateCurrentTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayLinkTimer = timer
    }

    private func stopPositionUpdates() {
        displayLinkTimer?.invalidate()
        displayLinkTimer = nil
    }

    private func updateCurrentTime() {
        guard state == .playing, !isSeeking,
              let nodeTime = instrumentalPlayer.lastRenderTime,
              let playerTime = instrumentalPlayer.playerTime(forNodeTime: nodeTime) else { return }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        let elapsed = Double(scheduleOriginFrame) / sampleRate + max(0, played)
        currentTime = max(0, min(duration, elapsed))
    }

    // MARK: - Interruptions

    /// Call when the audio session is interrupted or the route goes away.
    public func handleInterruption() {
        if state == .playing { pause() }
    }

    /// Call when the engine's configuration changes (route change, sample-rate
    /// change). Re-establishes the graph and resumes from where we were.
    public func handleEngineConfigurationChange() {
        guard let vocalBuffer else { return }
        let resumeAt = currentTime
        let wasPlaying = state == .playing

        vocalPlayer.stop()
        instrumentalPlayer.stop()
        do {
            try connectGraph(format: vocalBuffer.format)
            try startEngineIfNeeded()
        } catch {
            state = .ready
            return
        }
        schedule(fromFrame: AVAudioFramePosition(resumeAt * sampleRate))
        currentTime = resumeAt
        state = wasPlaying ? .paused : .ready
        if wasPlaying { play() }
    }
}

public enum KaraokePlayerError: LocalizedError {
    case mismatchedStems
    case bufferAllocationFailed
    case engineFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .mismatchedStems:
            return "The vocal and instrumental stems don't match."
        case .bufferAllocationFailed:
            return "Not enough memory to play that track."
        case .engineFailed(let underlying):
            return "Audio playback couldn't start: \(underlying.localizedDescription)"
        }
    }
}
#endif
