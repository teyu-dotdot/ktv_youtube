import Foundation

#if canImport(AVFoundation)
import AVFoundation

/// Errors raised while decoding or converting audio.
public enum AudioConversionError: LocalizedError {
    case unsupportedFormat
    case decodeFailed(underlying: Error)
    case emptyFile
    case bufferAllocationFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "That audio format can't be read on this device."
        case .decodeFailed(let underlying):
            return "The audio couldn't be decoded: \(underlying.localizedDescription)"
        case .emptyFile:
            return "The audio file is empty."
        case .bufferAllocationFailed:
            return "Not enough memory to load that track."
        }
    }
}

public extension AudioSignal {
    /// Reads a whole file into memory as deinterleaved float PCM.
    ///
    /// Anything that `AVAudioFile` can open works: the m4a/opus/webm the
    /// resolver hands back, plus whatever the user imports from Files.
    static func decode(contentsOf url: URL) throws -> AudioSignal {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioConversionError.decodeFailed(underlying: error)
        }

        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw AudioConversionError.emptyFile }

        // Normalise to non-interleaved float32 at the file's own sample rate;
        // the engine resamples once, at output, rather than per stem.
        let channels = min(max(sourceFormat.channelCount, 1), 2)
        guard let workingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw AudioConversionError.unsupportedFormat
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: workingFormat, frameCapacity: frameCount) else {
            throw AudioConversionError.bufferAllocationFailed
        }

        if sourceFormat == workingFormat {
            do {
                try file.read(into: buffer)
            } catch {
                throw AudioConversionError.decodeFailed(underlying: error)
            }
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: workingFormat) else {
                throw AudioConversionError.unsupportedFormat
            }
            var readError: Error?
            var reachedEnd = false
            var conversionError: NSError?

            let status = converter.convert(to: buffer, error: &conversionError) { packetCount, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard let source = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat, frameCapacity: packetCount
                ) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: source, frameCount: packetCount)
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if source.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return source
            }

            if let readError {
                throw AudioConversionError.decodeFailed(underlying: readError)
            }
            if status == .error {
                if let conversionError {
                    throw AudioConversionError.decodeFailed(underlying: conversionError)
                }
                throw AudioConversionError.unsupportedFormat
            }
        }

        guard let signal = AudioSignal(buffer: buffer) else {
            throw AudioConversionError.unsupportedFormat
        }
        return signal
    }

    /// Wraps a non-interleaved float32 buffer. Returns nil for other layouts.
    init?(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return nil }

        var channels: [[Float]] = []
        channels.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            channels.append(Array(UnsafeBufferPointer(start: data[channel], count: frames)))
        }
        self.init(channels: channels, sampleRate: buffer.format.sampleRate)
    }

    /// Renders back into an `AVAudioPCMBuffer` for scheduling on a player node.
    func makeBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)
        ), let data = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<channelCount {
            channels[channel].withUnsafeBufferPointer { source in
                data[channel].update(from: source.baseAddress!, count: frameCount)
            }
        }
        return buffer
    }
}
#endif
