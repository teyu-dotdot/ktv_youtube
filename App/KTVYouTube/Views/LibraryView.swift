import SwiftUI
import KaraokeKit

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Binding var isShowingAddSheet: Bool
    @Binding var isShowingSettings: Bool
    @State private var searchText = ""

    private var filteredTracks: [Track] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.library.tracks }
        return model.library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.artist?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(filteredTracks) { track in
                TrackRow(track: track, stage: model.library.importProgress[track.id])
                    .tag(track.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            model.delete(track)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }
            .onDelete { offsets in
                for index in offsets {
                    model.delete(filteredTracks[index])
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Search songs")
        .navigationTitle("Songs")
        .overlay {
            if model.library.tracks.isEmpty {
                ContentUnavailableView {
                    Label("Your library is empty", systemImage: "music.note.list")
                } description: {
                    Text("Add a YouTube link or import audio from Files.")
                }
            } else if filteredTracks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Label("Add song", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedTrack?.id },
            set: { newValue in
                guard let newValue,
                      let track = model.library.track(withID: newValue) else { return }
                Task { await model.open(track) }
            }
        )
    }
}

struct TrackRow: View {
    let track: Track
    let stage: TrackPreparer.Stage?

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.artworkURL, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(track.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let duration = track.duration {
                        Text(TimeFormatting.string(from: duration))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer(minLength: 0)

            if let stage {
                ImportIndicator(stage: stage)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Progress for a track that is still downloading.
private struct ImportIndicator: View {
    let stage: TrackPreparer.Stage

    var body: some View {
        Group {
            if let fraction = stage.fraction, fraction < 1 {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
            } else {
                ProgressView()
            }
        }
        .controlSize(.small)
        .accessibilityLabel(stage.message)
    }
}

struct Artwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
    }
}

enum TimeFormatting {
    /// `m:ss`, or `h:mm:ss` past an hour.
    static func string(from interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
