import Foundation

/// A deinterleaved block of 32-bit float PCM.
///
/// Deliberately free of AVFoundation so the DSP layer stays testable on any
/// platform; conversion to and from `AVAudioPCMBuffer` lives in the Audio layer.
public struct AudioSignal: Equatable, Sendable {
    /// One array per channel, each `frameCount` samples long.
    public var channels: [[Float]]
    public var sampleRate: Double

    public init(channels: [[Float]], sampleRate: Double) {
        precondition(!channels.isEmpty, "AudioSignal needs at least one channel")
        precondition(channels.allSatisfy { $0.count == channels[0].count },
                     "all channels must be the same length")
        self.channels = channels
        self.sampleRate = sampleRate
    }

    public var channelCount: Int { channels.count }
    public var frameCount: Int { channels[0].count }
    public var duration: TimeInterval {
        sampleRate > 0 ? TimeInterval(frameCount) / sampleRate : 0
    }
    public var isStereo: Bool { channelCount >= 2 }

    /// Silence of the given shape.
    public static func silence(channels: Int, frames: Int, sampleRate: Double) -> AudioSignal {
        AudioSignal(
            channels: Array(repeating: [Float](repeating: 0, count: frames), count: channels),
            sampleRate: sampleRate
        )
    }

    /// Peak absolute sample across every channel.
    public var peak: Float {
        channels.reduce(Float(0)) { partial, channel in
            max(partial, channel.reduce(Float(0)) { max($0, abs($1)) })
        }
    }

    /// Root-mean-square level across every channel, in dBFS.
    public var rmsDecibels: Float {
        var sum: Double = 0
        var count = 0
        for channel in channels {
            for sample in channel {
                sum += Double(sample) * Double(sample)
            }
            count += channel.count
        }
        guard count > 0 else { return -.infinity }
        let rms = (sum / Double(count)).squareRoot()
        return rms > 0 ? Float(20 * log10(rms)) : -.infinity
    }

    /// Scales every channel in place so the loudest sample sits at `target`.
    /// No-op for silence, and never boosts beyond `maximumGain`.
    public mutating func normalize(to target: Float = 0.97, maximumGain: Float = 4.0) {
        let currentPeak = peak
        guard currentPeak > 1e-6 else { return }
        let gain = min(target / currentPeak, maximumGain)
        guard gain < 0.999 || gain > 1.001 else { return }
        for index in channels.indices {
            for sampleIndex in channels[index].indices {
                channels[index][sampleIndex] *= gain
            }
        }
    }
}
