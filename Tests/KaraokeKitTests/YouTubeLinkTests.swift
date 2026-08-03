import XCTest
@testable import KaraokeKit

final class YouTubeLinkTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"

    func testStandardWatchURL() {
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/watch?v=\(id)")?.videoID, id)
    }

    func testAcceptsEveryCommonForm() {
        let inputs = [
            "https://www.youtube.com/watch?v=\(id)",
            "http://youtube.com/watch?v=\(id)",
            "https://m.youtube.com/watch?v=\(id)",
            "https://music.youtube.com/watch?v=\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "https://youtu.be/\(id)",
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/live/\(id)",
            "https://www.youtube.com/v/\(id)",
            "youtube.com/watch?v=\(id)",
            "www.youtube.com/watch?v=\(id)",
            id
        ]
        for input in inputs {
            XCTAssertEqual(YouTubeLink.parse(input)?.videoID, id, "failed on \(input)")
        }
    }

    func testExtraQueryParametersAreIgnored() {
        let url = "https://www.youtube.com/watch?v=\(id)&list=PLabc&index=3&pp=xyz"
        XCTAssertEqual(YouTubeLink.parse(url)?.videoID, id)
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(YouTubeLink.parse("  https://youtu.be/\(id)\n")?.videoID, id)
    }

    func testTimestampParsing() {
        XCTAssertEqual(YouTubeLink.parse("https://youtu.be/\(id)?t=90")?.startTime, 90)
        XCTAssertEqual(YouTubeLink.parse("https://youtu.be/\(id)?t=90s")?.startTime, 90)
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/watch?v=\(id)&t=1m30s")?.startTime, 90)
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/watch?v=\(id)&t=1h2m3s")?.startTime, 3723)
        XCTAssertNil(YouTubeLink.parse("https://youtu.be/\(id)")?.startTime)
    }

    func testRejectsNonYouTubeInput() {
        let inputs = [
            "",
            "   ",
            "hello world",
            "https://vimeo.com/12345678",
            "https://notyoutube.com/watch?v=\(id)",
            "https://www.youtube.com/watch?v=tooshort",
            "https://www.youtube.com/watch?v=waytoolongtobeanid",
            "https://www.youtube.com/feed/subscriptions",
            "https://youtu.be/",
            // A lookalike host that merely ends in the real one.
            "https://evilyoutube.com/watch?v=\(id)"
        ]
        for input in inputs {
            XCTAssertNil(YouTubeLink.parse(input), "should have rejected \(input)")
        }
    }

    func testVideoIDCharacterSet() {
        XCTAssertTrue(YouTubeLink.isValidVideoID("abcDEF-_123"))
        XCTAssertFalse(YouTubeLink.isValidVideoID("abcDEF-_12"))      // 10 chars
        XCTAssertFalse(YouTubeLink.isValidVideoID("abcDEF-_1234"))    // 12 chars
        XCTAssertFalse(YouTubeLink.isValidVideoID("abcDEF-_12!"))     // bad character
        XCTAssertFalse(YouTubeLink.isValidVideoID("abcDEF-_12é"))     // non-ASCII
    }

    func testCanonicalAndThumbnailURLs() {
        let link = YouTubeLink(videoID: id)
        XCTAssertEqual(link.canonicalURL.absoluteString, "https://www.youtube.com/watch?v=\(id)")
        XCTAssertEqual(link.thumbnailURL.absoluteString, "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    func testDurationParsing() {
        XCTAssertEqual(YouTubeLink.parseDuration("42"), 42)
        XCTAssertEqual(YouTubeLink.parseDuration("2m"), 120)
        XCTAssertEqual(YouTubeLink.parseDuration("1h"), 3600)
        XCTAssertEqual(YouTubeLink.parseDuration("1h1m1s"), 3661)
        XCTAssertNil(YouTubeLink.parseDuration("abc"))
        XCTAssertNil(YouTubeLink.parseDuration(""))
    }
}

final class YouTubePlaylistTests: XCTestCase {
    private let listID = "PLrAXtmRdnEQy6nuLMfO6uJz7WLqLpNMkC"

    func testParsesTheFormsYouTubeUses() {
        for input in [
            "https://www.youtube.com/playlist?list=\(listID)",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=\(listID)",
            "https://m.youtube.com/playlist?list=\(listID)",
            "youtube.com/playlist?list=\(listID)",
            listID
        ] {
            XCTAssertEqual(YouTubePlaylist.parse(input)?.listID, listID, "failed on \(input)")
        }
    }

    func testRejectsNonPlaylists() {
        for input in [
            "",
            "   ",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://vimeo.com/playlist?list=\(listID)",
            "https://www.youtube.com/playlist?list=nope",
            "dQw4w9WgXcQ"
        ] {
            XCTAssertNil(YouTubePlaylist.parse(input), "should have rejected \(input)")
        }
    }

    func testListIDPrefixes() {
        XCTAssertTrue(YouTubePlaylist.isValidListID(listID))
        XCTAssertTrue(YouTubePlaylist.isValidListID("UUabcdefghijklmno"))
        XCTAssertFalse(YouTubePlaylist.isValidListID("XXabcdefghijklmno"), "unknown prefix")
        XCTAssertFalse(YouTubePlaylist.isValidListID("PLshort"), "too short")
        XCTAssertFalse(YouTubePlaylist.isValidListID("PLabcdefghij!klmno"), "bad character")
    }

    /// The handover URL is what makes YouTube advance through the queue itself
    /// rather than the app racing its autoplay.
    func testAnonymousPlaylistURL() {
        let ids = ["dQw4w9WgXcQ", "abcDEF-_123"]
        XCTAssertEqual(
            YouTubePlaylist.anonymousPlaylistURL(videoIDs: ids)?.absoluteString,
            "https://www.youtube.com/watch_videos?video_ids=dQw4w9WgXcQ,abcDEF-_123"
        )
    }

    func testAnonymousPlaylistDropsRubbishAndCaps() {
        let mixed = ["dQw4w9WgXcQ", "not-an-id", "abcDEF-_123"]
        XCTAssertEqual(
            YouTubePlaylist.anonymousPlaylistURL(videoIDs: mixed)?.absoluteString,
            "https://www.youtube.com/watch_videos?video_ids=dQw4w9WgXcQ,abcDEF-_123"
        )
        XCTAssertNil(YouTubePlaylist.anonymousPlaylistURL(videoIDs: []))
        XCTAssertNil(YouTubePlaylist.anonymousPlaylistURL(videoIDs: ["nope"]))

        let many = Array(repeating: "dQw4w9WgXcQ", count: 80)
        let url = YouTubePlaylist.anonymousPlaylistURL(videoIDs: many, limit: 50)
        XCTAssertEqual(url?.absoluteString.components(separatedBy: ",").count, 50)
    }

    func testURLs() {
        let playlist = YouTubePlaylist(listID: listID)
        XCTAssertTrue(playlist.watchURL.absoluteString.contains("list=\(listID)"))
        XCTAssertEqual(
            playlist.pageURL.absoluteString,
            "https://www.youtube.com/playlist?list=\(listID)"
        )
    }
}
