import SwiftUI
import KaraokeKit

@main
struct KTVYouTubeApp: App {
    @State private var model: AppModel

    init() {
        // A failure here means Application Support is unwritable, which in
        // practice means the device is out of space. Fall back to a temporary
        // directory so the app still launches and can explain itself.
        let storage: LibraryStorage
        do {
            storage = try LibraryStorage.default()
        } catch {
            let fallback = LibraryStorage(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("KTVYouTube", isDirectory: true)
            )
            try? fallback.createDirectories()
            storage = fallback
        }
        _model = State(initialValue: AppModel(storage: storage))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { model.start() }
                // Accepts audio dragged in from Files or shared from another app.
                .onOpenURL { url in
                    Task { await model.importFile(at: url) }
                }
        }
    }
}
