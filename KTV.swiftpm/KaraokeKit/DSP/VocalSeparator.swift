import Foundation

/// Splits a stereo mix into a vocal estimate and an instrumental estimate.
///
/// ## How it works
///
/// Lead vocals are mixed to the centre in essentially every commercial
/// recording: the same signal, at the same level and phase, in both speakers.
/// Instruments are spread around it. So "how centred is this?" is a usable
/// stand-in for "how vocal is this?".
///
/// For each STFT bin we build a soft mask from two independent pieces of
/// evidence, then multiply them:
///
/// * **Phase coherence** — `2|L·conj(R)| / (|L|² + |R|²)`. This is 1 when the
///   two channels carry the same waveform and falls towards 0 as they
///   decorrelate. It ignores overall level, so it survives mixes where the
///   channels aren't perfectly matched.
/// * **Level balance** — `1 - ||L| - |R|| / (|L| + |R|)`. This is 1 for a bin
///   sitting dead centre and 0 for one hard-panned to a single speaker.
///
/// A band weighting then rolls the mask off below `lowCutHz` and above
/// `highCutHz` so the (also centred, also coherent) kick and bass survive, and
/// so cymbals keep their air.
///
/// ## Why the two stems always sum back to the input
///
/// Only the vocal estimate is resynthesised. The instrumental is computed in
/// the time domain as `original - vocal`, which makes the reconstruction exact
/// to floating-point precision rather than merely close. That matters for
/// playback: the app crossfades between the stems with a "vocal level" fader,
/// and at 100% the listener must hear the untouched original, not a mix that
/// has been through a lossy analysis/synthesis round trip.
public final class VocalSeparator {
    /// The two stems, which sum sample-for-sample back to the input.
    public struct Result: Sendable {
        /// The isolated-vocal estimate. Mostly useful as a monitoring/preview
        /// stem and as the thing the vocal fader brings back in.
        public var vocal: AudioSignal
        /// The backing track: the input with the vocal estimate removed.
        public var instrumental: AudioSignal
    }

    /// Raised by `separate` when the caller's cancellation handler returns true.
    public struct CancelledError: Error, Equatable {
        public init() {}
    }

    public private(set) var settings: SeparationSettings

    public init(settings: SeparationSettings = .balanced) {
        precondition(settings.fftSize >= 64 && settings.fftSize & (settings.fftSize - 1) == 0,
                     "fftSize must be a power of two >= 64")
        self.settings = settings
    }

    /// Separates `signal` into vocal and instrumental stems.
    ///
    /// - Parameters:
    ///   - signal: stereo input. Mono input is handled by
    ///     ``separateMono(_:)``, which can only do a band-limited approximation.
    ///   - progress: called on the calling thread with a value in `0...1`.
    ///   - isCancelled: polled between frames; return `true` to abort.
    /// - Throws: ``CancelledError`` if `isCancelled` returned true.
    public func separate(
        _ signal: AudioSignal,
        progress: ((Double) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Result {
        // A mono file, or a "fake stereo" file with two identical channels, has
        // no panning information to work with. Centre extraction would classify
        // the entire midrange as vocal and gut the track, so fall back.
        guard signal.isStereo, !Self.channelsAreEffectivelyIdentical(signal) else {
            return separateMono(signal, progress: progress)
        }

        let n = settings.fftSize
        let hop = settings.hopSize
        let frameCount = signal.frameCount
        guard frameCount > 0 else {
            return Result(
                vocal: .silence(channels: signal.channelCount, frames: 0, sampleRate: signal.sampleRate),
                instrumental: signal
            )
        }

        let window = HannWindow.periodic(length: n)
        let fft = FFT(size: n)

        // The signal is treated as if it were padded by a full window at the
        // front — so the first real sample is covered by as many overlapping
        // frames as the middle of the track — and by two more at the back to
        // flush the final frames. The padding is *virtual*: samples outside the
        // real signal read as zero rather than being materialised into a copy,
        // which matters because one buffer for a five-minute stereo track is
        // already ~100 MB.
        let leadingPad = n
        let paddedLength = leadingPad + frameCount + 2 * n
        let analysisFrames = (paddedLength - n) / hop + 1

        let left = signal.channels[0]
        let right = signal.channels[1]

        // Accumulates the windowed vocal estimate, then is normalised in place
        // to become the vocal stem itself.
        var vocalAccumulator = [[Float]](
            repeating: [Float](repeating: 0, count: frameCount), count: 2
        )
        var windowSquaredSum = [Float](repeating: 0, count: frameCount)

        let bandWeights = bandWeighting(fftSize: n, sampleRate: signal.sampleRate)

        var leftReal = [Float](repeating: 0, count: n)
        var leftImag = [Float](repeating: 0, count: n)
        var rightReal = [Float](repeating: 0, count: n)
        var rightImag = [Float](repeating: 0, count: n)
        var mask = [Float](repeating: 0, count: n / 2 + 1)

        let progressStride = max(1, analysisFrames / 100)

        for frame in 0..<analysisFrames {
            if frame % progressStride == 0 {
                if isCancelled?() == true { throw CancelledError() }
                progress?(Double(frame) / Double(analysisFrames))
            }

            let start = frame * hop
            guard start + n <= paddedLength else { break }

            for i in 0..<n {
                let source = start + i - leadingPad
                let w = window[i]
                if source >= 0 && source < frameCount {
                    leftReal[i] = left[source] * w
                    rightReal[i] = right[source] * w
                } else {
                    leftReal[i] = 0
                    rightReal[i] = 0
                }
                leftImag[i] = 0
                rightImag[i] = 0
            }

            fft.forward(real: &leftReal, imag: &leftImag)
            fft.forward(real: &rightReal, imag: &rightImag)

            computeMask(
                leftReal: leftReal, leftImag: leftImag,
                rightReal: rightReal, rightImag: rightImag,
                bandWeights: bandWeights,
                into: &mask
            )

            // The mask is real, so mirroring it across the Nyquist point keeps
            // the spectrum conjugate-symmetric and the inverse transform real.
            for k in 0...(n / 2) {
                let m = mask[k]
                leftReal[k] *= m
                leftImag[k] *= m
                rightReal[k] *= m
                rightImag[k] *= m
                let mirror = n - k
                if mirror < n && mirror != k {
                    leftReal[mirror] *= m
                    leftImag[mirror] *= m
                    rightReal[mirror] *= m
                    rightImag[mirror] *= m
                }
            }

            fft.inverse(real: &leftReal, imag: &leftImag)
            fft.inverse(real: &rightReal, imag: &rightImag)

            // Weighted overlap-add: window a second time on synthesis, and
            // divide by the accumulated window energy once at the end.
            for i in 0..<n {
                let destination = start + i - leadingPad
                guard destination >= 0, destination < frameCount else { continue }
                let w = window[i]
                vocalAccumulator[0][destination] += leftReal[i] * w
                vocalAccumulator[1][destination] += rightReal[i] * w
                windowSquaredSum[destination] += w * w
            }
        }

        // Normalise the accumulator in place, and derive the instrumental by
        // subtraction so the two stems sum back to the input exactly.
        var instrumentalChannels = [[Float]](repeating: [], count: 2)
        for channel in 0..<2 {
            var instrumental = [Float](repeating: 0, count: frameCount)
            let source = signal.channels[channel]
            for i in 0..<frameCount {
                let norm = windowSquaredSum[i]
                let v = norm > 1e-6 ? vocalAccumulator[channel][i] / norm : 0
                vocalAccumulator[channel][i] = v
                instrumental[i] = source[i] - v
            }
            instrumentalChannels[channel] = instrumental
        }

        progress?(1.0)
        return Result(
            vocal: AudioSignal(channels: vocalAccumulator, sampleRate: signal.sampleRate),
            instrumental: AudioSignal(channels: instrumentalChannels, sampleRate: signal.sampleRate)
        )
    }

    // MARK: - Mask

    private func computeMask(
        leftReal: [Float], leftImag: [Float],
        rightReal: [Float], rightImag: [Float],
        bandWeights: [Float],
        into mask: inout [Float]
    ) {
        let epsilon: Float = 1e-12
        let similarityExponent = settings.similarityExponent
        let balanceExponent = settings.balanceExponent
        let strength = max(0, min(1, settings.strength))

        for k in 0..<mask.count {
            let lr = leftReal[k], li = leftImag[k]
            let rr = rightReal[k], ri = rightImag[k]

            let leftPower = lr * lr + li * li
            let rightPower = rr * rr + ri * ri
            let totalPower = leftPower + rightPower
            guard totalPower > epsilon else {
                mask[k] = 0
                continue
            }

            // |L * conj(R)|
            let crossReal = lr * rr + li * ri
            let crossImag = li * rr - lr * ri
            let crossMagnitude = (crossReal * crossReal + crossImag * crossImag).squareRoot()
            let coherence = min(1, max(0, 2 * crossMagnitude / totalPower))

            let leftMagnitude = leftPower.squareRoot()
            let rightMagnitude = rightPower.squareRoot()
            let magnitudeSum = leftMagnitude + rightMagnitude
            let balance = magnitudeSum > epsilon
                ? min(1, max(0, 1 - abs(leftMagnitude - rightMagnitude) / magnitudeSum))
                : 0

            let value = Self.raise(coherence, to: similarityExponent)
                * Self.raise(balance, to: balanceExponent)
            mask[k] = min(1, max(0, value * bandWeights[k] * strength))
        }
    }

    /// `powf` shows up in profiles here — it runs once per bin per frame per
    /// channel, so tens of millions of times on a full track. The presets only
    /// use small integral and half-integral exponents, so special-case those.
    @inline(__always)
    private static func raise(_ base: Float, to exponent: Float) -> Float {
        switch exponent {
        case 1.0: return base
        case 2.0: return base * base
        case 3.0: return base * base * base
        case 0.5: return base.squareRoot()
        case 0.0: return 1
        default: return pow(base, exponent)
        }
    }

    /// True when this signal will go down the (much weaker) mono path, because
    /// there is no stereo information to separate on.
    public static func usesMonoFallback(for signal: AudioSignal) -> Bool {
        !signal.isStereo || channelsAreEffectivelyIdentical(signal)
    }

    /// True when the two channels are the same signal, within a small
    /// tolerance. Sampled rather than exhaustive: a decimated pass over the
    /// whole file is enough to tell dual-mono from a real stereo mix.
    static func channelsAreEffectivelyIdentical(_ signal: AudioSignal) -> Bool {
        guard signal.channelCount >= 2 else { return true }
        let left = signal.channels[0]
        let right = signal.channels[1]
        let stride = max(1, left.count / 20_000)

        var differenceEnergy: Double = 0
        var signalEnergy: Double = 0
        var index = 0
        while index < left.count {
            let difference = Double(left[index] - right[index])
            let sum = Double(left[index] + right[index])
            differenceEnergy += difference * difference
            signalEnergy += sum * sum
            index += stride
        }

        guard signalEnergy > 1e-12 else { return true }
        // -60 dB of side energy relative to mid is inaudible as stereo width.
        return differenceEnergy / signalEnergy < 1e-6
    }

    /// Per-bin weighting that protects the extremes of the spectrum.
    private func bandWeighting(fftSize: Int, sampleRate: Double) -> [Float] {
        let binCount = fftSize / 2 + 1
        let nyquist = Float(sampleRate / 2)
        let lowCut = max(1, settings.lowCutHz)
        let highCut = settings.highCutHz
        var weights = [Float](repeating: 1, count: binCount)

        for k in 0..<binCount {
            let frequency = Float(k) * Float(sampleRate) / Float(fftSize)
            if frequency < lowCut {
                let ramp = frequency / lowCut
                weights[k] = ramp * ramp
            } else if frequency > highCut && nyquist > highCut {
                let ramp = max(0, 1 - (frequency - highCut) / (nyquist - highCut))
                weights[k] = ramp * ramp
            }
        }
        return weights
    }

    // MARK: - Mono

    /// Mono input carries no panning information, so centre extraction is
    /// impossible. All we can do is attenuate the band the voice usually
    /// occupies, which is audibly worse — the UI warns before using it.
    private func separateMono(
        _ signal: AudioSignal,
        progress: ((Double) -> Void)?
    ) -> Result {
        // Average the channels first so a dual-mono file collapses cleanly.
        let source: [Float]
        if signal.channelCount >= 2 {
            let left = signal.channels[0], right = signal.channels[1]
            source = (0..<left.count).map { 0.5 * (left[$0] + right[$0]) }
        } else {
            source = signal.channels[0]
        }

        let vocalEstimate = MonoVocalNotch(sampleRate: signal.sampleRate).process(source)

        let depth: Float = 0.7 * max(0, min(1, settings.strength))
        var vocal = [Float](repeating: 0, count: source.count)
        var instrumental = [Float](repeating: 0, count: source.count)
        for i in 0..<source.count {
            let v = vocalEstimate[i] * depth
            vocal[i] = v
            instrumental[i] = source[i] - v
        }

        progress?(1.0)
        let channels = signal.channelCount
        return Result(
            vocal: AudioSignal(
                channels: Array(repeating: vocal, count: channels),
                sampleRate: signal.sampleRate
            ),
            instrumental: AudioSignal(
                channels: Array(repeating: instrumental, count: channels),
                sampleRate: signal.sampleRate
            )
        )
    }
}
