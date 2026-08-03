import Foundation

/// Downloads resolved audio to the media directory, reporting progress.
public struct MediaDownloader: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public enum DownloadError: LocalizedError {
        case badResponse(statusCode: Int)
        case writeFailed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let statusCode):
                return "The audio couldn't be downloaded (HTTP \(statusCode))."
            case .writeFailed(let underlying):
                return "The audio couldn't be saved: \(underlying.localizedDescription)"
            }
        }
    }

    /// Downloads `media` to `destination`, replacing anything already there.
    ///
    /// Uses a download task rather than `URLSession.bytes`, which vends one
    /// element per byte and would spend more time in the async sequence than in
    /// the network for a multi-megabyte file.
    ///
    /// - Parameter progress: fractional progress in `0...1`, or `nil` when the
    ///   server doesn't send a content length.
    public func download(
        _ media: ResolvedMedia,
        to destination: URL,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: media.audioURL)
        request.timeoutInterval = 120

        let observer = DownloadProgressObserver(onProgress: progress)
        let (temporaryURL, response) = try await session.download(for: request, delegate: observer)

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DownloadError.badResponse(statusCode: http.statusCode)
        }

        let manager = FileManager.default
        do {
            try? manager.removeItem(at: destination)
            // The temporary file is deleted as soon as this call returns, so
            // move rather than copy, and do it before any await.
            try manager.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw DownloadError.writeFailed(underlying: error)
        }
        progress?(1.0)
    }

    /// Copies a user-picked file into the media directory.
    ///
    /// Files coming from the document picker are security-scoped, so the caller
    /// is responsible for `startAccessingSecurityScopedResource()`.
    public func copyLocalFile(at url: URL, to destination: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        do {
            try manager.copyItem(at: url, to: destination)
        } catch {
            throw DownloadError.writeFailed(underlying: error)
        }
    }
}

/// Bridges `URLSessionDownloadDelegate` progress callbacks to a closure.
private final class DownloadProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (@Sendable (Double?) -> Void)?

    init(onProgress: (@Sendable (Double?) -> Void)?) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            onProgress?(nil)
            return
        }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// Required by the protocol. `URLSession.download(for:delegate:)` handles
    /// the completed file itself, so there's nothing to do here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
