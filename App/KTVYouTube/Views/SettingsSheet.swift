import SwiftUI
import KaraokeKit

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var baseURLString = ""
    @State private var accessToken = ""
    @State private var apiKey = ""
    @State private var diskUsage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("AIza…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("YouTube API key")
                } footer: {
                    Text("""
                    All that's needed to find karaoke versions. Create one free \
                    at console.cloud.google.com — enable "YouTube Data API v3" \
                    and make an API key. No other machine required.

                    The free allowance is about 50 searches a day, which resets \
                    at midnight Pacific time.
                    """)
                }

                Section {
                    TextField("http://your-mac.local:8808", text: $baseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Access token (optional)", text: $accessToken)
                } header: {
                    Text("Helper service (optional)")
                } footer: {
                    Text("""
                    Only needed for songs with no karaoke version, where the app has to \
                    fetch the original and strip the vocals itself. It can also do the \
                    searching instead of an API key. There's a reference implementation \
                    in the project's server/ folder.

                    Karaoke videos found through search stream straight from YouTube and \
                    are never downloaded. Downloading originals is the other path, and \
                    that generally requires permission from the rights holder — YouTube's \
                    Terms of Service prohibit it without one.
                    """)
                }

                Section {
                    LabeledContent("Downloads and cache", value: diskUsage)
                    Button("Clear separation cache") {
                        model.library.clearSeparationCache()
                        refreshDiskUsage()
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Clearing the cache keeps your songs. Vocals are removed again "
                         + "the next time you open each one.")
                }

                Section("How it works") {
                    Text("""
                    Most songs already have a karaoke version on YouTube, with the real \
                    instrumental and lyrics on screen. Searching finds those, and they \
                    play back exactly as uploaded — nothing is downloaded, nothing is \
                    processed, and the backing track is the one the karaoke producer made.

                    For songs with no karaoke version, the app falls back to removing the \
                    vocals itself. Lead vocals sit in the centre of a stereo mix, so it \
                    analyses each short slice of the song, finds the frequencies centred \
                    in both channels, and pulls those into a separate track you can fade \
                    in and out. That runs on-device and never sends your audio anywhere, \
                    but it costs a little of the bass and drums, and it needs real stereo.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.library.resolverConfiguration = ResolverConfiguration(
                            baseURLString: baseURLString,
                            accessToken: accessToken,
                            youTubeAPIKey: apiKey
                        )
                        dismiss()
                    }
                }
            }
            .onAppear {
                let configuration = model.library.resolverConfiguration
                baseURLString = configuration.baseURLString
                accessToken = configuration.accessToken
                apiKey = configuration.youTubeAPIKey
                refreshDiskUsage()
            }
        }
    }

    private func refreshDiskUsage() {
        diskUsage = model.library.diskUsageDescription()
    }
}
