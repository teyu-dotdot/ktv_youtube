import XCTest
@testable import KaraokeKit

final class VocalSeparatorTests: XCTestCase {
    private let sampleRate: Double = 44_100

    // MARK: - Fixtures

    /// A centre-panned harmonic stack with vibrato, standing in for a lead vocal.
    private func makeVocal(seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        var phase = 0.0
        var output = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let f0 = 220.0 * (1 + 0.01 * sin(2 * .pi * 5 * t))
            phase += 2 * .pi * f0 / sampleRate
            var sample = 0.0
            for harmonic in 1...8 {
                sample += (1.0 / Double(harmonic)) * sin(Double(harmonic) * phase)
            }
            output[i] = Float(sample * 0.3 * (0.6 + 0.4 * sin(2 * .pi * 0.7 * t)))
        }
        return output
    }

    /// Two hard-panned instruments plus a centred bass line.
    private func makeBand(seconds: Double) -> [[Float]] {
        let count = Int(sampleRate * seconds)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let guitar = 0.25 * sin(2 * .pi * 330 * t) + 0.15 * sin(2 * .pi * 660 * t)
            let keys = 0.25 * sin(2 * .pi * 494 * t) + 0.15 * sin(2 * .pi * 988 * t)
            let bass = 0.35 * sin(2 * .pi * 55 * t)
            left[i] = Float(0.9 * guitar + 0.2 * keys + bass)
            right[i] = Float(0.2 * guitar + 0.9 * keys + bass)
        }
        return [left, right]
    }

    private func makeMix(seconds: Double = 2.0) -> (mix: AudioSignal, vocal: [Float], band: [[Float]]) {
        let vocal = makeVocal(seconds: seconds)
        let band = makeBand(seconds: seconds)
        let left = zip(band[0], vocal).map(+)
        let right = zip(band[1], vocal).map(+)
        return (AudioSignal(channels: [left, right], sampleRate: sampleRate), vocal, band)
    }

    /// Gain of `reference` still present in `signal`, in dB. Negative means
    /// suppressed; -inf means gone entirely.
    private func leakageDecibels(of reference: [[Float]], in signal: AudioSignal) -> Float {
        var numerator: Double = 0
        var denominator: Double = 0
        for channel in 0..<min(reference.count, signal.channelCount) {
            for i in 0..<reference[channel].count {
                numerator += Double(signal.channels[channel][i]) * Double(reference[channel][i])
                denominator += Double(reference[channel][i]) * Double(reference[channel][i])
            }
        }
        guard denominator > 0 else { return -.infinity }
        let gain = abs(numerator / denominator)
        return gain > 0 ? Float(20 * log10(gain)) : -.infinity
    }

    // MARK: - Tests

    /// The property the whole player design rests on: at full vocal level the
    /// listener hears the original recording, bit for bit.
    func testStemsSumBackToTheOriginal() throws {
        let (mix, _, _) = makeMix()
        let result = try VocalSeparator(settings: .balanced).separate(mix)

        XCTAssertEqual(result.vocal.frameCount, mix.frameCount)
        XCTAssertEqual(result.instrumental.frameCount, mix.frameCount)

        for channel in 0..<mix.channelCount {
            for i in 0..<mix.frameCount {
                let sum = result.vocal.channels[channel][i] + result.instrumental.channels[channel][i]
                XCTAssertEqual(sum, mix.channels[channel][i], accuracy: 1e-5,
                               "stems don't sum at channel \(channel) sample \(i)")
            }
        }
    }

    func testCentrePannedVocalIsSuppressed() throws {
        let (mix, vocal, _) = makeMix()
        let result = try VocalSeparator(settings: .balanced).separate(mix)

        let leakage = leakageDecibels(of: [vocal, vocal], in: result.instrumental)
        XCTAssertLessThan(leakage, -18, "expected the centred vocal to be well suppressed")
    }

    /// The panned instruments must survive: a separator that just deletes the
    /// midrange would pass the suppression test and be useless.
    func testPannedInstrumentsSurvive() throws {
        let (mix, _, band) = makeMix()
        let result = try VocalSeparator(settings: .balanced).separate(mix)

        // Measured around -1.3 dB: the mask does clip a little off the panned
        // parts, which is the unavoidable cost of centre extraction.
        let retained = leakageDecibels(of: band, in: result.instrumental)
        XCTAssertGreaterThan(retained, -2.0, "the backing track was gutted along with the vocal")
    }

    /// Aggressive should remove more voice than gentle. If the presets ever
    /// stop being ordered, the UI is lying to the user.
    func testPresetsAreOrderedBySuppression() throws {
        let (mix, vocal, _) = makeMix()

        let gentle = try VocalSeparator(settings: .gentle).separate(mix)
        let aggressive = try VocalSeparator(settings: .aggressive).separate(mix)

        let gentleLeak = leakageDecibels(of: [vocal, vocal], in: gentle.instrumental)
        let aggressiveLeak = leakageDecibels(of: [vocal, vocal], in: aggressive.instrumental)
        XCTAssertLessThan(aggressiveLeak, gentleLeak)
    }

    /// `strength: 0` disables the mask, so the instrumental is the input and
    /// the vocal stem is silent.
    func testZeroStrengthIsPassThrough() throws {
        let (mix, _, _) = makeMix(seconds: 1.0)
        var settings = SeparationSettings.balanced
        settings.strength = 0
        let result = try VocalSeparator(settings: settings).separate(mix)

        XCTAssertLessThan(result.vocal.peak, 1e-4)
        for channel in 0..<mix.channelCount {
            for i in stride(from: 0, to: mix.frameCount, by: 97) {
                XCTAssertEqual(result.instrumental.channels[channel][i],
                               mix.channels[channel][i], accuracy: 1e-5)
            }
        }
    }

    /// Bass is centred and coherent, exactly like a vocal, so only the band
    /// weighting keeps it. Verify it isn't collateral damage.
    func testCentredBassIsPreserved() throws {
        let count = Int(sampleRate * 1.5)
        var bass = [Float](repeating: 0, count: count)
        for i in 0..<count {
            bass[i] = Float(0.5 * sin(2 * .pi * 55 * Double(i) / sampleRate))
        }
        // Dead-centre bass with a little panned noise so the file reads as stereo.
        var left = bass, right = bass
        for i in 0..<count {
            left[i] += Float.random(in: -0.01...0.01)
            right[i] += Float.random(in: -0.01...0.01)
        }
        let mix = AudioSignal(channels: [left, right], sampleRate: sampleRate)

        // The band weighting at 55 Hz is (55/140)^2, so a little is still taken:
        // measured around -1.5 dB, versus the -28 dB a centred vocal gets.
        let result = try VocalSeparator(settings: .balanced).separate(mix)
        let retained = leakageDecibels(of: [bass, bass], in: result.instrumental)
        XCTAssertGreaterThan(retained, -2.5, "the low end was removed with the vocal")
    }

    /// Dual-mono input has no stereo image; centre extraction would delete the
    /// whole midrange, so it must take the fallback path instead.
    func testDualMonoTakesTheMonoFallback() throws {
        let vocal = makeVocal(seconds: 1.0)
        let mix = AudioSignal(channels: [vocal, vocal], sampleRate: sampleRate)

        XCTAssertTrue(VocalSeparator.usesMonoFallback(for: mix))

        let result = try VocalSeparator(settings: .balanced).separate(mix)
        // The fallback ducks rather than deletes, so plenty of signal remains.
        XCTAssertGreaterThan(result.instrumental.peak, 0.2 * mix.peak)
        for i in stride(from: 0, to: mix.frameCount, by: 89) {
            XCTAssertEqual(result.vocal.channels[0][i] + result.instrumental.channels[0][i],
                           mix.channels[0][i], accuracy: 1e-5)
        }
    }

    func testTrueStereoIsNotTreatedAsMono() {
        let (mix, _, _) = makeMix(seconds: 0.5)
        XCTAssertFalse(VocalSeparator.usesMonoFallback(for: mix))
    }

    func testCancellationStopsWork() {
        let (mix, _, _) = makeMix(seconds: 3.0)
        let separator = VocalSeparator(settings: .balanced)
        XCTAssertThrowsError(try separator.separate(mix, isCancelled: { true })) { error in
            XCTAssertTrue(error is VocalSeparator.CancelledError)
        }
    }

    func testProgressRunsFromStartToFinish() throws {
        let (mix, _, _) = makeMix(seconds: 1.0)
        var samples: [Double] = []
        _ = try VocalSeparator(settings: .balanced).separate(mix, progress: { samples.append($0) })

        XCTAssertEqual(samples.first, 0)
        XCTAssertEqual(samples.last, 1.0)
        XCTAssertEqual(samples, samples.sorted(), "progress went backwards")
    }
}
