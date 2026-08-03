import SwiftUI
import KaraokeKit

/// Finds karaoke versions of a song and adds them to the library.
///
/// The main way songs get in. Typing a title here is the whole flow — no link
/// to copy, no download, no vocal removal — because a karaoke upload already
/// is what the app would otherwise spend seconds trying to approximate.
/// Lives in the sidebar rather than a sheet, so queueing songs never covers
/// or interrupts what's playing — the whole point of a karaoke queue is that
/// people line up the next song while the current one is still going.
struct KaraokeSearchSheet: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var results: [KaraokeSearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var hasSearched = false

    private var isConfigured: Bool { model.library.resolverConfiguration.canSearch }

    var body: some View {
        Group {
                if !isConfigured {
                    notConfigured
                } else if isSearching {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let searchError {
                    ContentUnavailableView {
                        Label("Search failed", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(searchError)
                    } actions: {
                        Button("Try again") { runSearch() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if results.isEmpty && hasSearched {
                    noResults
                } else if results.isEmpty {
                    prompt
                } else {
                    resultList
                }
            }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Song title, or title and artist"
        )
        .onSubmit(of: .search, runSearch)
    }

    // MARK: - States

    private var resultList: some View {
        List(results) { result in
            Button {
                add(result, playNow: true)
            } label: {
                KaraokeResultRow(result: result)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    add(result, playNow: false)
                } label: {
                    Label("Queue", systemImage: "text.append")
                }
                .tint(.indigo)
            }
            .contextMenu {
                Button {
                    add(result, playNow: true)
                } label: {
                    Label("Play now", systemImage: "play.fill")
                }
                Button {
                    let track = model.library.addKaraokeVideo(result)
                    model.playNext(track)
                } label: {
                    Label("Play next", systemImage: "text.insert")
                }
                Button {
                    add(result, playNow: false)
                } label: {
                    Label("Add to queue", systemImage: "text.append")
                }
            }
        }
        .listStyle(.plain)
    }

    private var prompt: some View {
        ContentUnavailableView {
            Label("Search for a karaoke version", systemImage: "music.mic")
        } description: {
            Text("Most songs already have one on YouTube — with the real "
                 + "instrumental and lyrics on screen. Type a title to look.")
        }
    }

    private var noResults: some View {
        ContentUnavailableView {
            Label("No karaoke version found", systemImage: "magnifyingglass")
        } description: {
            Text("Nothing came back that looks like an instrumental. Try adding "
                 + "the artist's name, or add the original song instead and let "
                 + "the app remove the vocals itself.")
        } actions: {
            Button("Add the original instead") {
                model.presentAddOriginal(prefilling: query)
            }
            .buttonStyle(.bordered)
        }
    }

    private var notConfigured: some View {
        ContentUnavailableView {
            Label("Search isn't set up yet", systemImage: "gearshape")
        } description: {
            Text("Add a YouTube API key in Settings and search works on its own — "
                 + "no other machine needed. Or point the app at the helper "
                 + "service if you're running one.")
        }
    }

    // MARK: - Actions

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }

        isSearching = true
        searchError = nil
        Task {
            do {
                results = try await model.library.searchKaraoke(trimmed)
            } catch {
                results = []
                searchError = error.localizedDescription
            }
            hasSearched = true
            isSearching = false
        }
    }

    /// Adds the result to the library, then either starts it or queues it.
    ///
    /// Queueing deliberately keeps the sheet open — the point of a karaoke
    /// night is lining several songs up in one go.
    private func add(_ result: KaraokeSearchResult, playNow: Bool) {
        let track = model.library.addKaraokeVideo(result)
        if playNow {
            Task { await model.playNow(track) }
        } else {
            model.addToQueue(track)
        }
    }
}

private struct KaraokeResultRow: View {
    let result: KaraokeSearchResult

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: result.thumbnailURL, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    if let badge = result.confidence.badge {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                result.confidence == .high ? Color.green.opacity(0.2)
                                                           : Color.secondary.opacity(0.15),
                                in: Capsule()
                            )
                    }
                    Text(result.channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let views = result.viewCountDescription {
                        Text(views)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let duration = result.duration {
                        Text(TimeFormatting.string(from: duration))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer(minLength: 0)
            Image(systemName: "plus.circle")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
