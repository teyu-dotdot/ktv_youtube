import SwiftUI
import KaraokeKit

struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let track: Track

    @State private var scrubTime: TimeInterval?

    private var player: KaraokePlayer { model.player }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                if let stage = model.preparation {
                    PreparationBanner(stage: stage)
                } else if !track.isDownloaded {
                    NotDownloadedBanner()
                } else {
                    transport
                    VocalFader(
                        level: vocalLevelBinding,
                        isMonoSource: model.isMonoSource
                    )
                    controls
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, horizontalSizeClass == .regular ? 40 : 20)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                UpNextStrip()
            }
            .background(.bar)
        }
        .navigationTitle(track.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.persistPlayerSettings() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 16) {
            Artwork(url: track.artworkURL, size: horizontalSizeClass == .regular ? 260 : 180)
                .shadow(radius: 12, y: 6)
            VStack(spacing: 4) {
                Text(track.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(track.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { scrubTime ?? player.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    guard !editing, let target = scrubTime else { return }
                    player.seek(to: target)
                    scrubTime = nil
                }
            )
            .disabled(player.duration <= 0)

            HStack {
                Text(TimeFormatting.string(from: scrubTime ?? player.currentTime))
                Spacer()
                Text("-" + TimeFormatting.string(
                    from: max(0, player.duration - (scrubTime ?? player.currentTime))
                ))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            HStack(spacing: 28) {
                Button {
                    model.playPrevious()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title3)
                }
                .disabled(!model.queue.hasPrevious)
                .accessibilityLabel("Previous song")

                Button {
                    player.skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title)
                }
                .accessibilityLabel("Back 10 seconds")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 68))
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel(player.state == .playing ? "Pause" : "Play")

                Button {
                    player.skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title)
                }
                .accessibilityLabel("Forward 10 seconds")

                Button {
                    model.skipToNext()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title3)
                }
                .disabled(!model.queue.hasNext)
                .accessibilityLabel("Skip to next song")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(.top, 4)
        }
    }

    private var controls: some View {
        VStack(spacing: 24) {
            KeyControl(
                semitones: Binding(
                    get: { player.pitchSemitones },
                    set: {
                        player.pitchSemitones = $0
                        model.persistPlayerSettings()
                    }
                )
            )

            LabeledSlider(
                title: "Tempo",
                systemImage: "metronome",
                value: Binding(
                    get: { Double(player.tempo) },
                    set: { player.tempo = Float($0) }
                ),
                range: 0.75...1.25,
                valueLabel: String(format: "%.2f×", player.tempo)
            )

            PresetPicker(
                preset: Binding(
                    get: { track.preset },
                    set: { newPreset in
                        Task { await model.applyPreset(newPreset) }
                    }
                )
            )
        }
    }

    private var vocalLevelBinding: Binding<Double> {
        Binding(
            get: { Double(player.vocalLevel) },
            set: { player.vocalLevel = Float($0) }
        )
    }
}

// MARK: - Vocal fader

/// The control the whole app exists for: how much of the original singer to
/// leave in the mix.
private struct VocalFader: View {
    @Binding var level: Double
    let isMonoSource: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Original vocal", systemImage: "music.mic")
                    .font(.headline)
                Spacer()
                Text(percentLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $level, in: 0...1) {
                Text("Original vocal level")
            } minimumValueLabel: {
                Image(systemName: "speaker.slash")
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.2")
            }

            HStack(spacing: 8) {
                ForEach([("Karaoke", 0.0), ("Guide", 0.25), ("Original", 1.0)], id: \.0) { name, value in
                    Button(name) { withAnimation(.easeOut(duration: 0.15)) { level = value } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if isMonoSource {
                Label(
                    "This recording is mono, so there's no stereo image to separate. "
                    + "Vocal removal will be much weaker than usual.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(20)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var percentLabel: String {
        level < 0.005 ? "Off" : "\(Int((level * 100).rounded()))%"
    }
}

// MARK: - Controls

private struct KeyControl: View {
    @Binding var semitones: Float

    var body: some View {
        HStack {
            Label("Key", systemImage: "pianokeys")
            Spacer()
            Button {
                semitones = max(-12, (semitones - 1).rounded())
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)
            .disabled(semitones <= -12)

            Text(keyLabel)
                .font(.body.monospacedDigit())
                .frame(minWidth: 46)

            Button {
                semitones = min(12, (semitones + 1).rounded())
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(semitones >= 12)

            Button("Reset") { semitones = 0 }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(semitones == 0)
        }
    }

    private var keyLabel: String {
        let value = Int(semitones.rounded())
        if value == 0 { return "0" }
        return value > 0 ? "+\(value)" : "\(value)"
    }
}

private struct LabeledSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(valueLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) { Text(title) }
        }
    }
}

private struct PresetPicker: View {
    @Binding var preset: SeparationSettings.Preset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Removal strength", systemImage: "waveform.badge.minus")
            Picker("Removal strength", selection: $preset) {
                ForEach(SeparationSettings.Preset.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Text(preset.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Banners

private struct PreparationBanner: View {
    let stage: TrackPreparer.Stage

    var body: some View {
        VStack(spacing: 12) {
            if let fraction = stage.fraction, fraction < 1 {
                ProgressView(value: fraction) {
                    Text(stage.message)
                }
                .progressViewStyle(.linear)
            } else {
                ProgressView {
                    Text(stage.message)
                }
            }
            if case .separating = stage {
                Text("This runs once per song, then it's cached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct NotDownloadedBanner: View {
    var body: some View {
        ContentUnavailableView {
            Label("Audio not downloaded", systemImage: "arrow.down.circle.dotted")
        } description: {
            Text("This song's audio isn't on the device yet. Remove it and add it again.")
        }
    }
}
