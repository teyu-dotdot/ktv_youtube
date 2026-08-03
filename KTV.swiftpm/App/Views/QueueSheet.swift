import SwiftUI
import KaraokeKit

/// The running order — what's playing and what's coming up.
struct QueueSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false

    var body: some View {
        NavigationStack {
            List {
                if let playing = model.selectedTrack {
                    Section("Now playing") {
                        QueueRow(track: playing, isPlaying: true)
                    }
                }

                Section {
                    if model.upNextTracks.isEmpty {
                        Text("Nothing queued. Add songs from search or hold one in your library.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        // Offsets here are into `upNext`, which is exactly what
                        // the queue's editing methods expect.
                        ForEach(Array(model.upNextTracks.enumerated()), id: \.offset) { offset, track in
                            Button {
                                model.jumpInQueue(to: offset)
                                dismiss()
                            } label: {
                                QueueRow(track: track, isPlaying: false)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { model.removeFromQueue(at: $0) }
                        .onMove { model.moveInQueue(from: $0, to: $1) }
                    }
                } header: {
                    HStack {
                        Text("Up next")
                        Spacer()
                        if !model.upNextTracks.isEmpty {
                            Button("Clear") { model.clearUpNext() }
                                .font(.caption)
                                .textCase(nil)
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditing ? "Finish" : "Reorder") {
                        withAnimation { isEditing.toggle() }
                    }
                    .disabled(model.upNextTracks.isEmpty)
                }
            }
        }
    }
}

private struct QueueRow: View {
    let track: Track
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.artworkURL, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                Text(track.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Now playing")
            } else if let duration = track.duration {
                Text(TimeFormatting.string(from: duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Queue actions, shared by library rows and search results so both offer the
/// same verbs.
struct QueueActionButtons: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        Button {
            Task { await model.playNow(track) }
        } label: {
            Label("Play now", systemImage: "play.fill")
        }
        Button {
            model.playNext(track)
        } label: {
            Label("Play next", systemImage: "text.insert")
        }
        Button {
            model.addToQueue(track)
        } label: {
            Label("Add to queue", systemImage: "text.append")
        }
    }
}
