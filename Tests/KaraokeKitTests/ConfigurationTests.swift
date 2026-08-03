import XCTest
@testable import KaraokeKit

final class ResolverConfigurationTests: XCTestCase {
    func testEmptyConfigurationIsNotUsable() {
        XCTAssertNil(ResolverConfiguration().baseURL)
        XCTAssertFalse(ResolverConfiguration().isConfigured)
        XCTAssertNil(ResolverConfiguration(baseURLString: "   ").baseURL)
    }

    func testAssumesHTTPSWhenNoSchemeIsGiven() {
        let configuration = ResolverConfiguration(baseURLString: "resolver.example.com")
        XCTAssertEqual(configuration.baseURL?.absoluteString, "https://resolver.example.com")
    }

    func testKeepsAnExplicitScheme() {
        // Local network services are usually plain HTTP.
        let configuration = ResolverConfiguration(baseURLString: "http://mac.local:8808")
        XCTAssertEqual(configuration.baseURL?.absoluteString, "http://mac.local:8808")
    }

    func testStripsTrailingSlashes() {
        let configuration = ResolverConfiguration(baseURLString: "http://mac.local:8808/")
        XCTAssertEqual(configuration.baseURL?.absoluteString, "http://mac.local:8808")
    }

    func testTrimsSurroundingWhitespace() {
        let configuration = ResolverConfiguration(baseURLString: "  http://mac.local:8808  ")
        XCTAssertEqual(configuration.baseURL?.host, "mac.local")
    }

    func testMakeResolverNeedsABaseURL() {
        XCTAssertNil(ResolverConfiguration().makeResolver())
        XCTAssertNotNil(ResolverConfiguration(baseURLString: "http://mac.local:8808").makeResolver())
    }

    func testBlankTokenIsTreatedAsAbsent() {
        let configuration = ResolverConfiguration(baseURLString: "http://mac.local", accessToken: "   ")
        let resolver = configuration.makeResolver() as? HTTPMediaResolver
        XCTAssertNil(resolver?.accessToken)
    }
}

final class SeparationSettingsTests: XCTestCase {
    func testHopIsQuarterOfTheWindow() {
        XCTAssertEqual(SeparationSettings(fftSize: 4096).hopSize, 1024)
        XCTAssertEqual(SeparationSettings(fftSize: 2048).hopSize, 512)
    }

    func testPresetsAreDistinctAndOrdered() {
        let presets = SeparationSettings.Preset.allCases
        XCTAssertEqual(presets, [.gentle, .balanced, .aggressive])
        XCTAssertNotEqual(SeparationSettings.gentle, SeparationSettings.aggressive)

        // Gentler presets demand a tighter centre match before removing a bin.
        XCTAssertGreaterThan(
            SeparationSettings.gentle.similarityExponent,
            SeparationSettings.aggressive.similarityExponent
        )
        XCTAssertGreaterThan(
            SeparationSettings.gentle.balanceExponent,
            SeparationSettings.aggressive.balanceExponent
        )
    }

    func testEveryPresetHasUserFacingText() {
        for preset in SeparationSettings.Preset.allCases {
            XCTAssertFalse(preset.title.isEmpty)
            XCTAssertFalse(preset.detail.isEmpty)
        }
    }

    func testRoundTripsThroughCoding() throws {
        let original = SeparationSettings.aggressive
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SeparationSettings.self, from: data), original)
    }
}

final class TrackTests: XCTestCase {
    func testIsDownloadedFollowsTheMediaFile() {
        var track = Track(title: "Song", source: .youTube(videoID: "dQw4w9WgXcQ"))
        XCTAssertFalse(track.isDownloaded)
        track.mediaFileName = "abc.m4a"
        XCTAssertTrue(track.isDownloaded)
    }

    func testSubtitleFallsBackToTheSource() {
        let youTube = Track(title: "Song", source: .youTube(videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(youTube.subtitle, "YouTube")

        let imported = Track(title: "Song", source: .importedFile(originalName: "song.m4a"))
        XCTAssertEqual(imported.subtitle, "Imported")

        var withArtist = youTube
        withArtist.artist = "Some Band"
        XCTAssertEqual(withArtist.subtitle, "Some Band")
    }

    func testVideoIDAccessor() {
        XCTAssertEqual(TrackSource.youTube(videoID: "dQw4w9WgXcQ").youTubeVideoID, "dQw4w9WgXcQ")
        XCTAssertNil(TrackSource.importedFile(originalName: "a.m4a").youTubeVideoID)
    }

    func testRoundTripsThroughCoding() throws {
        let original = Track(
            title: "Song",
            artist: "Band",
            source: .youTube(videoID: "dQw4w9WgXcQ"),
            mediaFileName: "abc.m4a",
            duration: 213,
            preset: .aggressive,
            vocalLevel: 0.25,
            pitchSemitones: -2
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode([original])
        let decoded = try decoder.decode([Track].self, from: data)
        XCTAssertEqual(decoded.first, original)
    }
}
