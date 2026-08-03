import SwiftUI
import UniformTypeIdentifiers
import KaraokeKit

struct AddTrackSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var linkText = ""
    @State private var isImporting = false
    @State private var isShowingFileImporter = false

    private var parsedLink: YouTubeLink? { YouTubeLink.parse(linkText) }
    private var resolverIsConfigured: Bool {
        model.library.resolverConfiguration.isConfigured
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("youtube.com/watch?v=…", text: $linkText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(1...3)
                        .onSubmit(addLink)

                    Button {
                        addLink()
                    } label: {
                        HStack {
                            Text("Add from YouTube")
                            if isImporting {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(parsedLink == nil || isImporting || !resolverIsConfigured)
                } header: {
                    Text("YouTube link")
                } footer: {
                    if !resolverIsConfigured {
                        Text("Set up a resolver service in Settings before adding YouTube links. "
                             + "You can import audio files without one.")
                    } else if !linkText.isEmpty && parsedLink == nil {
                        Text("That doesn't look like a YouTube link.")
                            .foregroundStyle(.red)
                    } else {
                        Text("The audio is downloaded once, then vocals are removed on this device.")
                    }
                }

                Section {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("Choose a file", systemImage: "folder")
                    }
                    .disabled(isImporting)
                } header: {
                    Text("Import audio")
                } footer: {
                    Text("Any audio your iPad can play. Stereo recordings work best — "
                         + "vocal removal needs a stereo image to work with.")
                }
            }
            .navigationTitle("Add a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importFile(url)
                case .failure(let error):
                    model.presentError(error.localizedDescription)
                }
            }
            .interactiveDismissDisabled(isImporting)
        }
    }

    private func addLink() {
        guard parsedLink != nil, !isImporting else { return }
        isImporting = true
        let input = linkText
        Task {
            await model.addYouTubeLink(input)
            isImporting = false
            // Stay open on failure so the link isn't lost and can be retried.
            if model.errorMessage == nil { dismiss() }
        }
    }

    private func importFile(_ url: URL) {
        isImporting = true
        Task {
            await model.importFile(at: url)
            isImporting = false
            if model.errorMessage == nil { dismiss() }
        }
    }
}
