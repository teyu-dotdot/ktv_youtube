import Foundation

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

/// Owns the app's `AVAudioSession` and forwards the events a player needs to
/// react to: interruptions (a call arrives), route changes (headphones out).
@MainActor
public final class AudioSessionController {
    public static let shared = AudioSessionController()

    /// Invoked when playback must stop right now.
    public var onInterruptionBegan: (() -> Void)?
    /// Invoked when the system says it's fine to resume.
    public var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    /// Invoked when the output route changed in a way that should pause playback
    /// (the classic "headphones yanked out" case).
    public var onRouteDisconnected: (() -> Void)?

    private var isConfigured = false

    private init() {}

    /// Configures the session for karaoke playback and starts observing.
    ///
    /// `.playback` keeps audio going when the iPad is locked or the app is
    /// backgrounded, and `.longFormAudio` opts into the AirPlay 2 picker so a
    /// user can push the backing track to a HomePod or Apple TV.
    public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setActive(true, options: [])

        guard !isConfigured else { return }
        isConfigured = true

        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.handleInterruption(notification) }
        }
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.handleRouteChange(notification) }
        }
    }

    public func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            try? AVAudioSession.sharedInstance().setActive(true)
            onInterruptionEnded?(options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            onRouteDisconnected?()
        }
    }
}
#endif
