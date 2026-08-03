import Foundation
import Observation
import SwiftUI
import KaraokeKit

/// Everything the app keeps track of, which is now very little.
///
/// The running order lives in a YouTube playlist rather than here. Dropping the
/// local queue took the library, the search index and the vocal separator with
/// it: YouTube already plays a playlist in order, and a second copy of that
/// state on the iPad only ever had to be kept in sync with the real one.
@MainActor
@Observable
final class AppModel {
    /// API key and shared playlist. Persisted in `UserDefaults`.
    var configuration: ResolverConfiguration {
        didSet { configuration.save() }
    }

    /// Which half of the stereo pair to play — the 原唱/伴唱 switch.
    var channelMode: AudioChannelMode = .both

    var isShowingSettings = false

    /// Injects CSS to strip YouTube's page chrome.
    ///
    /// Off by default and staying that way. An earlier version of this hid the
    /// container the player was about to be built into, which stopped it being
    /// built at all — a black screen is far too costly a failure for something
    /// purely cosmetic, so it's opt-in even though the ordering bug is fixed.
    var pageTweaksEnabled: Bool = UserDefaults.standard.object(forKey: "player.pageTweaks") as? Bool ?? false {
        didSet { UserDefaults.standard.set(pageTweaksEnabled, forKey: "player.pageTweaks") }
    }

    init() {
        configuration = .load()
    }

    var playlist: YouTubePlaylist? { configuration.sharedPlaylist }

    /// Accepts a playlist link, a bare id, or the contents of a scanned QR code.
    @discardableResult
    func setPlaylist(_ input: String) -> Bool {
        guard let playlist = YouTubePlaylist.parse(input) else { return false }
        configuration.sharedPlaylistID = playlist.listID
        return true
    }

    func clearPlaylist() {
        configuration.sharedPlaylistID = ""
    }
}
