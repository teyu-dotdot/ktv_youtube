import Foundation

/// Decides which search results are actually karaoke tracks.
///
/// A Swift twin of `server/karaoke_scoring.py`, kept in step with it. It exists
/// because the app can search two ways — through the helper service, which
/// ranks server-side, or directly against the YouTube Data API with nothing but
/// an API key, which has to rank here. The second path is what lets the whole
/// app run from an iPad with no other machine involved.
///
/// Search alone isn't enough: a query for a song plus "karaoke" happily returns
/// the original recording, a live version, and half a dozen covers. Since these
/// play back untouched, putting a track with vocals in front of someone who
/// wanted an instrumental is the one failure that really matters — so this
/// leans towards rejecting rather than guessing.
public enum KaraokeRanker {
    /// Unambiguous "this is an instrumental" markers.
    static let strongPositive = [
        // Chinese
        "伴奏", "ktv", "卡拉ok", "消音", "無人聲", "无人声", "去人聲", "去人声",
        // Japanese
        "カラオケ", "オフボーカル", "オフヴォーカル",
        // Korean
        "노래방",
        // English
        "karaoke", "instrumental", "off vocal", "offvocal", "backing track",
        "minus one", "sing along", "singalong"
    ]

    /// Suggestive but not conclusive.
    static let weakPositive = [
        "導唱", "导唱",          // guide vocal: quiet vocal left in, still singable
        "純音樂", "纯音乐",
        "no vocal", "without vocals", "vocal removed"
    ]

    /// Markers that the original singer is on the track, or it isn't a studio cut.
    static let strongNegative = [
        // Chinese
        "原唱", "翻唱", "現場", "现场", "演唱會", "演唱会", "直播",
        // Japanese
        "歌ってみた",
        // English
        "cover", "live", "reaction", "react", "lesson", "tutorial",
        "official video", "official mv", "music video", "behind the scenes"
    ]

    static let weakNegative = [
        "remix", "mashup", "nightcore", "sped up", "slowed",
        "teaser", "trailer", "preview", "shorts",
        // Compilations: karaoke, but an hour of it, and not the song asked for.
        "medley", "compilation", "nonstop", "non-stop", "連唱", "连唱", "串燒", "串烧"
    ]

    /// Channels whose whole output is karaoke are worth a nudge on their own.
    static let channelHints = ["karaoke", "ktv", "伴奏", "노래방", "カラオケ", "sing king", "zzang"]

    public struct Ranking: Equatable, Sendable {
        public var score: Int
        public var confidence: KaraokeSearchResult.Confidence
    }

    /// Ranks one result on how likely it is to be a usable karaoke track.
    public static func rank(
        title: String,
        channel: String = "",
        duration: TimeInterval? = nil
    ) -> Ranking {
        let haystack = " \(title.lowercased()) "
        let channelLower = channel.lowercased()
        var score = 0

        if strongPositive.contains(where: { haystack.contains($0.lowercased()) }) { score += 4 }
        if weakPositive.contains(where: { haystack.contains($0.lowercased()) }) { score += 2 }
        if containsMRTag(title) { score += 3 }
        if strongNegative.contains(where: { haystack.contains($0.lowercased()) }) { score -= 5 }
        if weakNegative.contains(where: { haystack.contains($0.lowercased()) }) { score -= 2 }
        if channelHints.contains(where: { channelLower.contains($0) }) { score += 2 }

        // A karaoke track runs about as long as the song. Much shorter is a
        // clip; much longer is a compilation or a livestream.
        if let duration {
            if duration < 60 {
                score -= 3
            } else if duration > 900 {
                score -= 6
            }
        }

        let confidence: KaraokeSearchResult.Confidence
        if score >= 6 {
            confidence = .high
        } else if score >= 3 {
            confidence = .medium
        } else {
            confidence = .low
        }
        return Ranking(score: score, confidence: confidence)
    }

    /// "MR" is the standard Korean tag for an instrumental, but it's also a
    /// word. Only count it standing alone and capitalised, so "Mr. Brightside"
    /// doesn't match.
    static func containsMRTag(_ title: String) -> Bool {
        let separators = Set(" \t[](){}-_|/".map { $0 })
        let characters = Array(title)
        var index = 0
        while index + 1 < characters.count {
            guard characters[index] == "M", characters[index + 1] == "R" else {
                index += 1
                continue
            }
            let beforeOK = index == 0 || separators.contains(characters[index - 1])
            let afterIndex = index + 2
            let afterOK = afterIndex == characters.count || separators.contains(characters[afterIndex])
            if beforeOK && afterOK { return true }
            index += 1
        }
        return false
    }

    // MARK: - Query planning

    /// Which language's karaoke vocabulary to search with.
    public enum Script: Equatable, Sendable {
        case latin, chinese, japanese, korean
    }

    /// Guesses the script a song title is written in.
    ///
    /// Japanese is checked before Chinese because Japanese titles are usually a
    /// mix of kana and kanji, and the kanji alone would look Chinese.
    public static func script(of query: String) -> Script {
        var hasHan = false
        for scalar in query.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF:      // hiragana, katakana
                return .japanese
            case 0xAC00...0xD7AF, 0x1100...0x11FF:      // hangul
                return .korean
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:      // CJK ideographs
                hasHan = true
            default:
                continue
            }
        }
        return hasHan ? .chinese : .latin
    }

    /// Query phrasings to try for a song, most specific first.
    ///
    /// Karaoke uploads are tagged in the language of their audience, and the
    /// words don't translate — a Korean upload says `MR`, a Chinese one `伴奏`.
    /// Picking by script keeps the number of searches down, which matters when
    /// each one costs API quota.
    public static func queries(for song: String, limit: Int = 2) -> [String] {
        let trimmed = song.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let phrasings: [String]
        switch script(of: trimmed) {
        case .chinese:
            phrasings = ["\(trimmed) 伴奏 KTV", "\(trimmed) karaoke instrumental",
                         "\(trimmed) 卡拉OK"]
        case .japanese:
            phrasings = ["\(trimmed) カラオケ オフボーカル", "\(trimmed) karaoke instrumental",
                         "\(trimmed) 伴奏"]
        case .korean:
            phrasings = ["\(trimmed) 노래방 MR", "\(trimmed) karaoke instrumental",
                         "\(trimmed) 반주"]
        case .latin:
            phrasings = ["\(trimmed) karaoke instrumental", "\(trimmed) backing track",
                         "\(trimmed) 伴奏 KTV"]
        }
        return Array(phrasings.prefix(max(1, limit)))
    }
}
