import XCTest
@testable import KaraokeKit

/// The expected scores here are the output of `server/karaoke_scoring.py` on
/// the same inputs. The two implementations must agree, or the app would rank
/// results differently depending on which search backend happened to be
/// configured.
final class KaraokeRankerTests: XCTestCase {
    private func score(_ title: String, _ channel: String, _ duration: TimeInterval?) -> Int {
        KaraokeRanker.rank(title: title, channel: channel, duration: duration).score
    }

    func testMatchesTheServerSideScores() {
        let cases: [(title: String, channel: String, duration: TimeInterval?, score: Int)] = [
            ("周杰倫 告白氣球 KTV伴奏", "KTV伴奏頻道", 215, 6),
            ("Ed Sheeran - Perfect (Karaoke Version)", "Sing King", 263, 6),
            ("IU - 좋은 날 MR 노래방", "KY Karaoke", 234, 9),
            ("米津玄師 Lemon カラオケ オフボーカル", "カラオケ庫", 256, 6),
            ("告白氣球 導唱版", "KTV Channel", 216, 4),
            ("Perfect - Ed Sheeran (Instrumental with Lyrics)", "Backing Tracks", 260, 4),
            ("周杰倫 - 告白氣球 (原唱)", "JVR Music", 215, -5),
            ("Ed Sheeran - Perfect (Official Music Video)", "Ed Sheeran", 263, -5),
            ("告白氣球 KTV伴奏 (30秒片段)", "clips", 30, 1),
            ("Karaoke Mix 2024 - 100 songs", "Karaoke Party", 7200, 0),
            ("Mr. Brightside - The Killers", "The Killers", 222, 0)
        ]

        for testCase in cases {
            XCTAssertEqual(
                score(testCase.title, testCase.channel, testCase.duration),
                testCase.score,
                "score drifted from the server implementation for: \(testCase.title)"
            )
        }
    }

    // MARK: - The decisions that matter

    /// Showing someone the original recording when they asked for karaoke is
    /// the failure that ruins the evening.
    func testOriginalsAndCoversAreRejected() {
        for title in [
            "周杰倫 - 告白氣球 (原唱)",
            "告白氣球 Cover by 小明",
            "Jay Chou - 告白氣球 Live 演唱會",
            "Lemon 歌ってみた",
            "Ed Sheeran - Perfect (Official Music Video)"
        ] {
            XCTAssertLessThanOrEqual(
                score(title, "", 220), 0, "should have been rejected: \(title)"
            )
        }
    }

    func testKaraokeUploadsAreAccepted() {
        for (title, channel) in [
            ("周杰倫 告白氣球 KTV伴奏", "KTV伴奏頻道"),
            ("Ed Sheeran - Perfect (Karaoke Version)", "Sing King"),
            ("IU - 좋은 날 MR 노래방", "KY Karaoke"),
            ("米津玄師 Lemon カラオケ オフボーカル", "カラオケ庫"),
            ("Perfect - Ed Sheeran (Instrumental)", "")
        ] {
            let ranking = KaraokeRanker.rank(title: title, channel: channel, duration: 240)
            XCTAssertNotEqual(
                ranking.confidence, .low, "should have been offered: \(title)"
            )
        }
    }

    /// "MR" is Korean for an instrumental, but it's also an English word.
    func testMRTagOnlyMatchesWhenStandingAlone() {
        XCTAssertTrue(KaraokeRanker.containsMRTag("좋은 날 MR"))
        XCTAssertTrue(KaraokeRanker.containsMRTag("MR 노래방"))
        XCTAssertTrue(KaraokeRanker.containsMRTag("[MR] 좋은 날"))
        XCTAssertTrue(KaraokeRanker.containsMRTag("좋은 날 (MR)"))

        XCTAssertFalse(KaraokeRanker.containsMRTag("Mr. Brightside"))
        XCTAssertFalse(KaraokeRanker.containsMRTag("MRI scan"))
        XCTAssertFalse(KaraokeRanker.containsMRTag("Mister"))
    }

    /// A karaoke compilation is karaoke, but it isn't the song that was asked
    /// for, and it'd sit at the top of the queue for an hour.
    func testCompilationsAndClipsAreDemoted() {
        XCTAssertEqual(
            KaraokeRanker.rank(title: "Karaoke Mix 2024", channel: "Karaoke Party", duration: 7200)
                .confidence, .low
        )
        XCTAssertEqual(
            KaraokeRanker.rank(title: "告白氣球 KTV伴奏", channel: "clips", duration: 30)
                .confidence, .low
        )
        // The same title at a normal length is fine.
        XCTAssertNotEqual(
            KaraokeRanker.rank(title: "告白氣球 KTV伴奏", channel: "clips", duration: 215)
                .confidence, .low
        )
    }

    func testConfidenceThresholds() {
        XCTAssertEqual(KaraokeRanker.rank(title: "x", channel: "", duration: 200).confidence, .low)
        // strong positive (4) + channel (2) = 6
        XCTAssertEqual(
            KaraokeRanker.rank(title: "song karaoke", channel: "Sing King", duration: 200).confidence,
            .high
        )
        // strong positive (4) alone
        XCTAssertEqual(
            KaraokeRanker.rank(title: "song karaoke", channel: "", duration: 200).confidence,
            .medium
        )
    }

    // MARK: - Query planning

    func testScriptDetection() {
        XCTAssertEqual(KaraokeRanker.script(of: "Perfect Ed Sheeran"), .latin)
        XCTAssertEqual(KaraokeRanker.script(of: "告白氣球"), .chinese)
        XCTAssertEqual(KaraokeRanker.script(of: "좋은 날"), .korean)
        XCTAssertEqual(KaraokeRanker.script(of: "レモン"), .japanese)
        // Japanese titles mix kana and kanji; the kana must win, or the kanji
        // would make it look Chinese and search with the wrong vocabulary.
        XCTAssertEqual(KaraokeRanker.script(of: "米津玄師 Lemon カラオケ"), .japanese)
        XCTAssertEqual(KaraokeRanker.script(of: "IU 좋은 날"), .korean)
    }

    func testQueriesUseTheRightVocabulary() {
        XCTAssertTrue(KaraokeRanker.queries(for: "告白氣球").contains { $0.contains("伴奏") })
        XCTAssertTrue(KaraokeRanker.queries(for: "좋은 날").contains { $0.contains("노래방") })
        XCTAssertTrue(KaraokeRanker.queries(for: "レモン").contains { $0.contains("カラオケ") })
        XCTAssertTrue(KaraokeRanker.queries(for: "Perfect").contains { $0.contains("karaoke") })
    }

    /// Each phrasing costs 100 units of a 10,000/day allowance, so the count
    /// has to stay where it's put.
    func testQueryCountIsCapped() {
        XCTAssertEqual(KaraokeRanker.queries(for: "song").count, 2)
        XCTAssertEqual(KaraokeRanker.queries(for: "song", limit: 1).count, 1)
        XCTAssertEqual(KaraokeRanker.queries(for: "song", limit: 0).count, 1, "never zero queries")
        XCTAssertTrue(KaraokeRanker.queries(for: "   ").isEmpty)
    }
}

final class ISO8601DurationTests: XCTestCase {
    private func parse(_ raw: String) -> TimeInterval? {
        YouTubeDataAPISearchClient.parseISO8601Duration(raw)
    }

    func testParsesTheFormsYouTubeReturns() {
        XCTAssertEqual(parse("PT4M13S"), 253)
        XCTAssertEqual(parse("PT45S"), 45)
        XCTAssertEqual(parse("PT3M"), 180)
        XCTAssertEqual(parse("PT1H2M3S"), 3723)
        XCTAssertEqual(parse("PT1H"), 3600)
    }

    func testRejectsNonsense() {
        XCTAssertNil(parse("banana"))
        XCTAssertNil(parse(""))
    }
}

final class SearchBackendSelectionTests: XCTestCase {
    func testNothingConfiguredMeansNoSearch() {
        let configuration = ResolverConfiguration()
        XCTAssertFalse(configuration.canSearch)
        XCTAssertNil(configuration.makeSearchClient())
    }

    /// An API key alone is a complete setup for the karaoke path — that's what
    /// makes an iPad-only install possible.
    func testAnAPIKeyAloneIsEnoughToSearch() {
        let configuration = ResolverConfiguration(youTubeAPIKey: "AIzaTest")
        XCTAssertTrue(configuration.canSearch)
        XCTAssertFalse(configuration.isConfigured, "no helper service, so no vocal-removal path")
        XCTAssertTrue(configuration.makeSearchClient() is YouTubeDataAPISearchClient)
    }

    func testTheHelperServiceCanSearchToo() {
        let configuration = ResolverConfiguration(baseURLString: "http://mac.local:8808")
        XCTAssertTrue(configuration.canSearch)
        XCTAssertTrue(configuration.makeSearchClient() is KaraokeSearchClient)
    }

    func testTheAPIKeyWinsWhenBothAreSet() {
        let configuration = ResolverConfiguration(
            baseURLString: "http://mac.local:8808",
            youTubeAPIKey: "AIzaTest"
        )
        XCTAssertTrue(configuration.makeSearchClient() is YouTubeDataAPISearchClient)
    }

    func testBlankAPIKeyFallsBackToTheService() {
        let configuration = ResolverConfiguration(
            baseURLString: "http://mac.local:8808",
            youTubeAPIKey: "   "
        )
        XCTAssertTrue(configuration.makeSearchClient() is KaraokeSearchClient)
    }
}
