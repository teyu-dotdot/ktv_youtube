import XCTest
@testable import KaraokeKit

final class PlaybackQueueTests: XCTestCase {
    // Stable, readable ids so failures point at a song rather than a UUID.
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func queue(_ ids: [UUID], current: Int?) -> PlaybackQueue {
        PlaybackQueue(entries: ids, currentIndex: current)
    }

    // MARK: - Empty

    func testEmptyQueue() {
        let queue = PlaybackQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.hasNext)
        XCTAssertFalse(queue.hasPrevious)
        XCTAssertTrue(queue.upNext.isEmpty)
    }

    func testAppendingToAnEmptyQueueStartsIt() {
        var queue = PlaybackQueue()
        queue.append(a)
        XCTAssertEqual(queue.current, a)
        XCTAssertTrue(queue.upNext.isEmpty)
    }

    // MARK: - A karaoke night, in order

    func testTypicalSession() {
        var queue = PlaybackQueue()
        queue.append(a)
        queue.append(b)
        queue.append(c)
        XCTAssertEqual(queue.current, a)
        XCTAssertEqual(queue.upNext, [b, c])

        // Someone jumps the line.
        let urgent = d
        queue.playNext(urgent)
        XCTAssertEqual(queue.upNext, [urgent, b, c], "play next should slot in right after the current song")
        XCTAssertEqual(queue.current, a, "play next must not change what's playing")

        XCTAssertEqual(queue.advance(), urgent)
        XCTAssertEqual(queue.history, [a])
        XCTAssertEqual(queue.upNext, [b, c])

        XCTAssertEqual(queue.goBack(), a)
        XCTAssertEqual(queue.upNext, [urgent, b, c])
    }

    func testPlayNowKeepsTheRestOfTheQueue() {
        var queue = self.queue([a, b, c], current: 0)
        queue.playNow(e)
        XCTAssertEqual(queue.current, e)
        XCTAssertEqual(queue.upNext, [b, c], "tapping a song shouldn't wipe what others queued")
        XCTAssertEqual(queue.history, [a])
    }

    func testPlayNextOnAnEmptyQueuePlaysImmediately() {
        var queue = PlaybackQueue()
        queue.playNext(a)
        XCTAssertEqual(queue.current, a)
    }

    // MARK: - Skipping

    func testAdvanceStopsAtTheEnd() {
        var queue = self.queue([a, b], current: 0)
        XCTAssertEqual(queue.advance(), b)
        XCTAssertFalse(queue.hasNext)
        XCTAssertNil(queue.advance(), "advancing past the end should report there's nothing there")
        XCTAssertEqual(queue.current, b, "and must not lose the current song")
    }

    func testGoBackStopsAtTheStart() {
        var queue = self.queue([a, b], current: 0)
        XCTAssertFalse(queue.hasPrevious)
        XCTAssertNil(queue.goBack())
        XCTAssertEqual(queue.current, a)
    }

    func testJumpingSkipsEverythingBetween() {
        var queue = self.queue([a, b, c, d, e], current: 0)
        XCTAssertEqual(queue.jumpToUpNext(offset: 2), d)
        XCTAssertEqual(queue.history, [a, b, c])
        XCTAssertEqual(queue.upNext, [e])
    }

    func testJumpingOutOfRangeDoesNothing() {
        var queue = self.queue([a, b], current: 0)
        XCTAssertNil(queue.jumpToUpNext(offset: 5))
        XCTAssertEqual(queue.current, a)
    }

    func testNextUpPreviewsWithoutMoving() {
        var queue = self.queue([a, b, c], current: 0)
        XCTAssertEqual(queue.nextUp, b)
        XCTAssertEqual(queue.current, a, "peeking must not advance")
        queue.advance()
        XCTAssertEqual(queue.nextUp, c)
    }

    // MARK: - Editing up next

    func testRemovingFromUpNextUsesOffsetsIntoThatList() {
        var queue = self.queue([a, b, c, d], current: 1)
        queue.removeUpNext(at: IndexSet(integer: 0))   // removes c
        XCTAssertEqual(queue.current, b)
        XCTAssertEqual(queue.upNext, [d])
        XCTAssertEqual(queue.history, [a], "removing from up next must not disturb history")
    }

    func testReorderingUpNext() {
        var queue = self.queue([a, b, c, d], current: 0)
        XCTAssertEqual(queue.upNext, [b, c, d])
        queue.moveUpNext(from: IndexSet(integer: 2), to: 0)   // d to the front
        XCTAssertEqual(queue.upNext, [d, b, c])
        XCTAssertEqual(queue.current, a)
    }

    func testClearingUpNext() {
        var queue = self.queue([a, b, c, d], current: 1)
        queue.clearUpNext()
        XCTAssertEqual(queue.current, b)
        XCTAssertTrue(queue.upNext.isEmpty)
        XCTAssertEqual(queue.entries, [a, b], "history should survive clearing up next")
    }

    func testClearingUpNextWhenAlreadyAtTheEnd() {
        var queue = self.queue([a, b], current: 1)
        queue.clearUpNext()
        XCTAssertEqual(queue.entries, [a, b])
    }

    // MARK: - Duplicates

    /// The same song really does get queued twice on a karaoke night, so the
    /// queue must not silently de-duplicate.
    func testDuplicatesAreKept() {
        var queue = PlaybackQueue()
        queue.append(a)
        queue.append(a)
        XCTAssertEqual(queue.entries, [a, a])
        XCTAssertEqual(queue.current, a)
        XCTAssertEqual(queue.upNext, [a])
    }

    func testRemovingOneDuplicateLeavesTheOther() {
        var queue = self.queue([a, b, a], current: 0)
        queue.removeUpNext(at: IndexSet(integer: 1))   // the second `a`
        XCTAssertEqual(queue.entries, [a, b])
    }

    // MARK: - Pruning after deletions

    func testPruneKeepsThePlayheadOnTheSameSong() {
        var queue = self.queue([a, b, c, d], current: 2)   // playing c
        queue.prune(keeping: [a, c, d])                    // b deleted
        XCTAssertEqual(queue.current, c)
        XCTAssertEqual(queue.entries, [a, c, d])
    }

    func testPruneWhenTheCurrentSongIsDeleted() {
        var queue = self.queue([a, b, c], current: 1)      // playing b
        queue.prune(keeping: [a, c])                       // b itself deleted
        XCTAssertEqual(queue.current, c, "should carry on from the same position")
        XCTAssertEqual(queue.entries, [a, c])
    }

    func testPruneToEmpty() {
        var queue = self.queue([a], current: 0)
        queue.prune(keeping: [])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.current)
    }

    // MARK: - Bulk

    func testReplace() {
        var queue = self.queue([a, b], current: 1)
        queue.replace(with: [c, d, e], startingAt: 1)
        XCTAssertEqual(queue.current, d)
        XCTAssertEqual(queue.upNext, [e])
        XCTAssertEqual(queue.history, [c])
    }

    func testReplaceWithNothingClearsTheQueue() {
        var queue = self.queue([a, b], current: 0)
        queue.replace(with: [])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.current)
    }

    func testOutOfRangeStartIndexIsClamped() {
        let queue = self.queue([a, b], current: 99)
        XCTAssertEqual(queue.current, b)
    }

    func testRemoveAll() {
        var queue = self.queue([a, b], current: 1)
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.hasPrevious)
    }
}
