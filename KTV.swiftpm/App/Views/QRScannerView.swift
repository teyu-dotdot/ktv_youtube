import SwiftUI
import AVFoundation
// AudioServicesPlaySystemSound lives here, not in AVFoundation.
import AudioToolbox

/// Scans a QR code and hands back whatever text it contained.
///
/// The point is getting a playlist onto the iPad without typing a link on a
/// television-sized screen with a floating keyboard. Whoever is hosting shares
/// the playlist from their phone, the phone shows a QR code, the iPad reads it.
struct QRScannerView: UIViewControllerRepresentable {
    /// Called once, with the first code found.
    let onScan: (String) -> Void
    /// Called when the camera can't be used at all, with something to show.
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        var onFailure: ((String) -> Void)?

        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        /// A QR code in view produces a stream of identical readings; only the
        /// first should count, or the sheet dismisses several times over.
        private var hasScanned = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        if granted {
                            self.configureSession()
                        } else {
                            self.onFailure?("Camera access was declined.")
                        }
                    }
                }
            default:
                onFailure?(
                    "This app doesn't have camera access. In Swift Playgrounds, "
                    + "turn on Camera under ⋯ ▸ App Settings; in a normal build, "
                    + "check Settings ▸ Privacy ▸ Camera."
                )
            }
        }

        private func configureSession() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onFailure?("No usable camera on this device.")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                onFailure?("The camera couldn't be set up to read codes.")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            // Set after adding to the session, or the type isn't available yet.
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            self.preview = preview

            startSession()
        }

        private func startSession() {
            guard !session.isRunning else { return }
            // Starting blocks for a moment, which would stutter the sheet's
            // presentation animation if it ran on the main thread.
            Task.detached(priority: .userInitiated) { [session] in
                session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasScanned,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            hasScanned = true
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            onScan?(value)
        }
    }
}

/// Presents the scanner and reports what it read.
struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let failure {
                    ContentUnavailableView {
                        Label("Can't use the camera", systemImage: "camera.fill")
                    } description: {
                        Text(failure)
                    }
                } else {
                    QRScannerView(
                        onScan: { value in
                            onScan(value)
                            dismiss()
                        },
                        onFailure: { failure = $0 }
                    )
                    .ignoresSafeArea()

                    VStack {
                        Spacer()
                        Text("Point the camera at a playlist QR code")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Scan playlist code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
