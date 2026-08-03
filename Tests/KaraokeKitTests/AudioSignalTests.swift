import XCTest
@testable import KaraokeKit

final class AudioSignalTests: XCTestCase {
    func testDurationAndShape() {
        let signal = AudioSignal.silence(channels: 2, frames: 44_100, sampleRate: 44_100)
        XCTAssertEqual(signal.channelCount, 2)
        XCTAssertEqual(signal.frameCount, 44_100)
        XCTAssertEqual(signal.duration, 1.0, accuracy: 1e-9)
        XCTAssertTrue(signal.isStereo)
    }

    func testPeak() {
        let signal = AudioSignal(channels: [[0.1, -0.7, 0.2], [0.3, 0.4, -0.5]], sampleRate: 48_000)
        XCTAssertEqual(signal.peak, 0.7, accuracy: 1e-6)
    }

    func testNormalizeScalesToTarget() {
        // Peak 0.6 needs a gain of 1.5, comfortably under the 4x ceiling.
        var signal = AudioSignal(channels: [[0.3, -0.6, 0.45]], sampleRate: 44_100)
        signal.normalize(to: 0.9)
        XCTAssertEqual(signal.peak, 0.9, accuracy: 1e-5)
    }

    func testNormalizeRespectsTheGainCeiling() {
        // A near-silent signal must not be amplified without limit.
        var signal = AudioSignal(channels: [[0.001, -0.001]], sampleRate: 44_100)
        signal.normalize(to: 0.97, maximumGain: 4)
        XCTAssertEqual(signal.peak, 0.004, accuracy: 1e-6)
    }

    func testNormalizeLeavesSilenceAlone() {
        var signal = AudioSignal.silence(channels: 2, frames: 128, sampleRate: 44_100)
        signal.normalize()
        XCTAssertEqual(signal.peak, 0)
    }

    func testRMSDecibels() {
        // A full-scale square wave sits at 0 dBFS RMS.
        let signal = AudioSignal(channels: [[1, -1, 1, -1]], sampleRate: 44_100)
        XCTAssertEqual(signal.rmsDecibels, 0, accuracy: 1e-4)
    }
}

final class HannWindowTests: XCTestCase {
    func testPeriodicWindowEndpoints() {
        let window = HannWindow.periodic(length: 8)
        XCTAssertEqual(window[0], 0, accuracy: 1e-6)
        XCTAssertEqual(window[4], 1, accuracy: 1e-6)
        // Periodic, not symmetric: the last sample is not zero.
        XCTAssertGreaterThan(window[7], 0)
    }

    /// The separator divides by this sum, so at 75% overlap it must settle to a
    /// constant 1.5 in the steady state — never zero.
    func testSquaredOverlapSumIsConstantInTheSteadyState() {
        let length = 64
        let hop = length / 4
        let sum = HannWindow.squaredOverlapSum(length: length, hop: hop, frames: 20)

        for index in (length)..<(sum.count - length) {
            XCTAssertEqual(sum[index], 1.5, accuracy: 1e-4, "overlap sum dipped at \(index)")
        }
    }
}

final class BiquadTests: XCTestCase {
    func testBandPassPassesItsCentreAndRejectsFarAway() {
        let sampleRate = 44_100.0
        let filter = Biquad.bandPass(centerHz: 1000, q: 1.0, sampleRate: sampleRate)

        func gain(at frequency: Double) -> Float {
            let count = Int(sampleRate)
            let input = (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
            let output = filter.process(input)
            // Skip the first half second so the filter has settled.
            let tail = output[(count / 2)...]
            let rms = (tail.reduce(Float(0)) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
            return rms * Float(2.0.squareRoot())
        }

        XCTAssertEqual(gain(at: 1000), 1.0, accuracy: 0.05)
        XCTAssertLessThan(gain(at: 100), 0.2)
        XCTAssertLessThan(gain(at: 10_000), 0.2)
    }

    func testStabilityWithLongInput() {
        let filter = Biquad.bandPass(centerHz: 300, q: 0.9, sampleRate: 44_100)
        let input = (0..<44_100).map { _ in Float.random(in: -1...1) }
        let output = filter.process(input)
        XCTAssertTrue(output.allSatisfy { $0.isFinite })
        XCTAssertLessThan(output.reduce(Float(0)) { max($0, abs($1)) }, 10)
    }
}
