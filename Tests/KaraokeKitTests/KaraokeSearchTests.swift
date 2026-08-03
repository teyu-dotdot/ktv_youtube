import XCTest
@testable import KaraokeKit

final class KaraokeSearchClientTests: XCTestCase {
    private func makeClient() -> KaraokeSearchClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return KaraokeSearchClient(
            baseURL: URL(string: "http://mac.local:8808")!,
            session: URLSession(configuration: configuration)
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDecodesResults() async throws {
        StubURLProtocol.respond(statusCode: 200, body: """
        {"results": [
          {"video_id": "dQw4w9WgXcQ", "title": "告白氣球 KTV伴奏", "channel": "KTV頻道",
           "duration": 215, "thumbnail": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
           "score": 6, "confidence": "high"}
        ]}
        """)

        let results = try await makeClient().search("告白氣球")
        XCTAssertEqual(results.count, 1)
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(first.title, "告白氣球 KTV伴奏")
        XCTAssertEqual(first.channel, "KTV頻道")
        XCTAssertEqual(first.duration, 215)
        XCTAssertEqual(first.confidence, .high)
    }

    func testSendsTheQueryAndLimit() async throws {
        StubURLProtocol.respond(statusCode: 200, body: #"{"results": []}"#)
        _ = try await makeClient().search("Perfect Ed Sheeran", limit: 5)

        let url = try XCTUnwrap(StubURLProtocol.lastRequestURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/search")
        XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, "Perfect Ed Sheeran")
        XCTAssertEqual(components.queryItems?.first { $0.name == "limit" }?.value, "5")
    }

    /// A malformed video id from the service must never reach the player, which
    /// would build an embed URL out of it.
    func testDropsResultsWithInvalidVideoIDs() async throws {
        StubURLProtocol.respond(statusCode: 200, body: """
        {"results": [
          {"video_id": "not-a-valid-id-at-all", "title": "bad", "confidence": "high"},
          {"video_id": "dQw4w9WgXcQ", "title": "good", "confidence": "high"}
        ]}
        """)

        let results = try await makeClient().search("anything")
        XCTAssertEqual(results.map(\.title), ["good"])
    }

    func testMissingOptionalFieldsAreTolerated() async throws {
        StubURLProtocol.respond(statusCode: 200, body: """
        {"results": [{"video_id": "dQw4w9WgXcQ", "title": "Only the essentials"}]}
        """)

        let first = try XCTUnwrap(try await makeClient().search("x").first)
        XCTAssertEqual(first.channel, "")
        XCTAssertNil(first.duration)
        XCTAssertNil(first.thumbnailURL)
        XCTAssertEqual(first.confidence, .low)
    }

    func testEmptyQueryDoesNotHitTheNetwork() async throws {
        StubURLProtocol.respond(statusCode: 500, body: "")
        let results = try await makeClient().search("   ")
        XCTAssertTrue(results.isEmpty)
        XCTAssertNil(StubURLProtocol.lastRequestURL)
    }

    func testSurfacesTheServiceErrorMessage() async {
        StubURLProtocol.respond(statusCode: 502, body: #"{"error": "The search failed."}"#)
        do {
            _ = try await makeClient().search("anything")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? KaraokeSearchError, .failed(reason: "The search failed."))
        }
    }

    func testReportsStatusCodeWhenThereIsNoMessage() async {
        StubURLProtocol.respond(statusCode: 503, body: "upstream is down")
        do {
            _ = try await makeClient().search("anything")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? KaraokeSearchError, .badResponse(statusCode: 503))
        }
    }

    func testRejectsUnreadableResponses() async {
        StubURLProtocol.respond(statusCode: 200, body: "this is not json")
        do {
            _ = try await makeClient().search("anything")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? KaraokeSearchError, .malformedResponse)
        }
    }

    func testUnconfiguredResolverMakesNoSearchClient() {
        XCTAssertNil(ResolverConfiguration().makeSearchClient())
        XCTAssertNotNil(
            ResolverConfiguration(baseURLString: "http://mac.local:8808").makeSearchClient()
        )
    }
}

final class KaraokeTrackSourceTests: XCTestCase {
    func testKaraokeVideosPlayInTheEmbeddedPlayer() {
        XCTAssertTrue(TrackSource.karaokeVideo(videoID: "dQw4w9WgXcQ").playsInEmbeddedPlayer)
        XCTAssertFalse(TrackSource.youTube(videoID: "dQw4w9WgXcQ").playsInEmbeddedPlayer)
        XCTAssertFalse(TrackSource.importedFile(originalName: "a.m4a").playsInEmbeddedPlayer)
    }

    func testVideoIDIsReadableFromBothYouTubeCases() {
        XCTAssertEqual(TrackSource.karaokeVideo(videoID: "dQw4w9WgXcQ").youTubeVideoID, "dQw4w9WgXcQ")
        XCTAssertEqual(TrackSource.youTube(videoID: "dQw4w9WgXcQ").youTubeVideoID, "dQw4w9WgXcQ")
        XCTAssertNil(TrackSource.importedFile(originalName: "a.m4a").youTubeVideoID)
    }

    /// Karaoke videos stream, so they're playable without anything on disk —
    /// unlike every other source.
    func testKaraokeVideosArePlayableWithoutADownload() {
        let karaoke = Track(title: "Song", source: .karaokeVideo(videoID: "dQw4w9WgXcQ"))
        XCTAssertTrue(karaoke.isPlayable)
        XCTAssertFalse(karaoke.isDownloaded)

        let original = Track(title: "Song", source: .youTube(videoID: "dQw4w9WgXcQ"))
        XCTAssertFalse(original.isPlayable)
    }

    func testSubtitleDistinguishesKaraokeVideos() {
        XCTAssertEqual(
            Track(title: "Song", source: .karaokeVideo(videoID: "dQw4w9WgXcQ")).subtitle,
            "Karaoke video"
        )
    }

    func testRoundTripsThroughCoding() throws {
        let original = Track(title: "Song", source: .karaokeVideo(videoID: "dQw4w9WgXcQ"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([Track].self, from: try encoder.encode([original]))
        XCTAssertEqual(decoded.first?.source, .karaokeVideo(videoID: "dQw4w9WgXcQ"))
    }
}

// MARK: - Test double

/// Serves a canned response so the client can be tested without a network.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statusCode = 200
    private static var body = ""
    private static var requestURL: URL?

    static func respond(statusCode: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        Self.statusCode = statusCode
        Self.body = body
        Self.requestURL = nil
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        Self.requestURL = nil
    }

    static var lastRequestURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return requestURL
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestURL = request.url
        let status = Self.statusCode
        let payload = Self.body
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
