import SwiftUI
import KaraokeKit

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var baseURLString = ""
    @State private var accessToken = ""
    @State private var diskUsage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://your-mac.local:8808", text: $baseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Access token (optional)", text: $accessToken)
                } header: {
                    Text("Resolver service")
                } footer: {
                    Text("""
                    iOS has no supported way to extract audio from YouTube, so this app \
                    doesn't try. Point it at a small service you run yourself — there's a \
                    reference implementation in the project's server/ folder — and the app \
                    will ask that service for a downloadable audio URL.

                    Only add content you have the rights to use. Downloading from YouTube \
                    generally requires permission from the rights holder, and YouTube's \
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
                    Lead vocals sit in the centre of a stereo mix. The app analyses each \
                    short slice of the song, works out which frequencies are centred in \
                    both channels, and pulls those out into a separate track. The fader in \
                    the player mixes that vocal track back in, so you can go from full \
                    karaoke to a guide vocal to the untouched original.

                    It's arithmetic on the stereo image, not an AI model, so it runs \
                    instantly on-device and never sends your audio anywhere — but it can't \
                    match a trained separator on dense mixes, and it needs real stereo.
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
                            accessToken: accessToken
                        )
                        dismiss()
                    }
                }
            }
            .onAppear {
                let configuration = model.library.resolverConfiguration
                baseURLString = configuration.baseURLString
                accessToken = configuration.accessToken
                refreshDiskUsage()
            }
        }
    }

    private func refreshDiskUsage() {
        diskUsage = model.library.diskUsageDescription()
    }
}
