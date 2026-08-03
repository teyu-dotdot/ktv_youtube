import Foundation

/// The running order of songs.
///
/// A value type on purpose: queue logic is fiddly enough to be worth testing
/// exhaustively, and that's much easier without an actor or a reference to
/// share. The app holds one of these and mutates it in place.
///
/// Duplicates are allowed — the same song genuinely does get queued twice on a
/// karaoke night — so every mutation that targets a specific entry works by
/// position rather than by id.
public struct PlaybackQueue: Equatable, Sendable {
    /// Every song in order, played and unplayed alike. `currentIndex` marks the
    /// boundary, which is what makes "previous" work.
    public private(set) var entries: [UUID]

    /// Position of the song playing now. `nil` when the queue is empty or has
    /// been played to the end.
    public private(set) var currentIndex: Int?

    public init(entries: [UUID] = [], currentIndex: Int? = nil) {
        self.entries = entries
        self.currentIndex = Self.clamp(currentIndex, to: entries)
    }

    // MARK: - Reading

    public var current: UUID? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    /// Songs after the current one, in the order they'll play.
    public var upNext: [UUID] {
        guard let currentIndex else { return entries }
        let start = currentIndex + 1
        guard start < entries.count else { return [] }
        return Array(entries[start...])
    }

    /// Songs already played, most recent last.
    public var history: [UUID] {
        guard let currentIndex, currentIndex > 0 else { return [] }
        return Array(entries[..<currentIndex])
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var hasNext: Bool { !upNext.isEmpty }
    public var hasPrevious: Bool { (currentIndex ?? 0) > 0 }

    /// What `advance()` would land on, without moving.
    public var nextUp: UUID? { upNext.first }

    // MARK: - Adding

    /// Plays `id` immediately, keeping whatever was already queued behind it.
    ///
    /// Used when a song is tapped in the library: it shouldn't wipe the queue
    /// everyone else has been adding to.
    public mutating func playNow(_ id: UUID) {
        let insertAt = (currentIndex.map { $0 + 1 }) ?? 0
        entries.insert(id, at: min(insertAt, entries.count))
        currentIndex = insertAt
    }

    /// Slots `id` in right after the current song.
    public mutating func playNext(_ id: UUID) {
        guard let currentIndex else {
            // Nothing playing, so "next" is just "now".
            entries.insert(id, at: 0)
            self.currentIndex = 0
            return
        }
        entries.insert(id, at: min(currentIndex + 1, entries.count))
    }

    /// Adds `id` to the end of the queue.
    public mutating func append(_ id: UUID) {
        entries.append(id)
        // Appending to a queue with nothing playing starts it from the top,
        // rather than jumping to the song just added.
        if currentIndex == nil { currentIndex = 0 }
    }

    /// Replaces the whole queue, starting at `index`.
    public mutating func replace(with ids: [UUID], startingAt index: Int = 0) {
        entries = ids
        currentIndex = ids.isEmpty ? nil : Self.clamp(index, to: ids)
    }

    // MARK: - Moving

    /// Steps to the next song. Returns what's now playing, or nil at the end.
    @discardableResult
    public mutating func advance() -> UUID? {
        guard hasNext else { return nil }
        // `?? -1` so a queue that has never started lands on the first entry.
        currentIndex = (currentIndex ?? -1) + 1
        return current
    }

    /// Steps back. Returns what's now playing, or nil if already at the start.
    @discardableResult
    public mutating func goBack() -> UUID? {
        guard hasPrevious, let currentIndex else { return nil }
        self.currentIndex = currentIndex - 1
        return current
    }

    /// Jumps to a position in `upNext`, skipping anything between.
    @discardableResult
    public mutating func jumpToUpNext(offset: Int) -> UUID? {
        guard upNext.indices.contains(offset) else { return nil }
        currentIndex = (currentIndex ?? -1) + 1 + offset
        return current
    }

    // MARK: - Removing

    /// Removes entries from `upNext` by their offsets in that list.
    public mutating func removeUpNext(at offsets: IndexSet) {
        let base = (currentIndex ?? -1) + 1
        let absolute = offsets
            .map { $0 + base }
            .filter { entries.indices.contains($0) }
            .sorted(by: >)     // back to front, so earlier indices stay valid
        for index in absolute {
            entries.remove(at: index)
        }
    }

    /// Reorders `upNext`. Offsets and destination are relative to that list.
    public mutating func moveUpNext(from source: IndexSet, to destination: Int) {
        let base = (currentIndex ?? -1) + 1
        let reordered = Self.moving(upNext, from: source, to: destination)
        entries.replaceSubrange(base..., with: reordered)
    }

    /// SwiftUI's `move(fromOffsets:toOffset:)`, implemented here rather than
    /// imported.
    ///
    /// That method — and `remove(atOffsets:)` — look like Standard Library
    /// collection APIs but are actually SwiftUI extensions. Using them would
    /// drag SwiftUI into this package, which is meant to stay platform-free so
    /// the DSP and the queue can be tested anywhere.
    ///
    /// The subtlety worth preserving: `destination` indexes the array *before*
    /// anything is removed, so it has to be adjusted by however many moved
    /// items sat in front of it.
    static func moving<Element>(
        _ elements: [Element],
        from source: IndexSet,
        to destination: Int
    ) -> [Element] {
        var result = elements
        let valid = source.filter { result.indices.contains($0) }.sorted()
        guard !valid.isEmpty else { return result }

        let moving = valid.map { result[$0] }
        let removedBeforeDestination = valid.filter { $0 < destination }.count

        for index in valid.reversed() {
            result.remove(at: index)
        }
        let insertAt = max(0, min(result.count, destination - removedBeforeDestination))
        result.insert(contentsOf: moving, at: insertAt)
        return result
    }

    /// Empties everything after the current song.
    public mutating func clearUpNext() {
        guard let currentIndex else {
            entries.removeAll()
            return
        }
        entries.removeSubrange((currentIndex + 1)...)
    }

    public mutating func removeAll() {
        entries.removeAll()
        currentIndex = nil
    }

    /// Drops entries whose tracks no longer exist, keeping the playhead on the
    /// same song where possible. Call after deleting from the library.
    public mutating func prune(keeping validIDs: Set<UUID>) {
        let playing = current
        entries.removeAll { !validIDs.contains($0) }

        guard !entries.isEmpty else {
            currentIndex = nil
            return
        }
        if let playing, let index = entries.firstIndex(of: playing) {
            currentIndex = index
        } else {
            // The song that was playing is gone; carry on from the same spot.
            currentIndex = Self.clamp(currentIndex, to: entries)
        }
    }

    // MARK: -

    private static func clamp(_ index: Int?, to entries: [UUID]) -> Int? {
        guard !entries.isEmpty, let index else { return nil }
        return max(0, min(entries.count - 1, index))
    }
}
