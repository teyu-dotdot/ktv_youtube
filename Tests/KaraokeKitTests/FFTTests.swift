import XCTest
@testable import KaraokeKit

final class FFTTests: XCTestCase {
    /// A pure tone must land entirely in its own bin.
    func testSingleBinTone() {
        let size = 512
        let bin = 7
        let fft = FFT(size: size)

        var real = (0..<size).map { Float(cos(2 * Double.pi * Double(bin) * Double($0) / Double(size))) }
        var imag = [Float](repeating: 0, count: size)
        fft.forward(real: &real, imag: &imag)

        for k in 0..<(size / 2 + 1) {
            let magnitude = (real[k] * real[k] + imag[k] * imag[k]).squareRoot()
            if k == bin {
                // cos splits its energy between +k and -k, so this bin gets N/2.
                XCTAssertEqual(magnitude, Float(size) / 2, accuracy: 0.01)
            } else {
                XCTAssertLessThan(magnitude, 0.01, "energy leaked into bin \(k)")
            }
        }
    }

    /// DC input puts everything in bin 0 and nothing anywhere else.
    func testDirectCurrent() {
        let size = 64
        let fft = FFT(size: size)
        var real = [Float](repeating: 1, count: size)
        var imag = [Float](repeating: 0, count: size)
        fft.forward(real: &real, imag: &imag)

        XCTAssertEqual(real[0], Float(size), accuracy: 0.001)
        XCTAssertEqual(imag[0], 0, accuracy: 0.001)
        for k in 1..<size {
            XCTAssertEqual((real[k] * real[k] + imag[k] * imag[k]).squareRoot(), 0, accuracy: 0.001)
        }
    }

    func testForwardInverseRoundTrip() {
        let size = 1024
        let fft = FFT(size: size)
        var generator = SystemRandomNumberGenerator()
        let original = (0..<size).map { _ in Float.random(in: -1...1, using: &generator) }

        var real = original
        var imag = [Float](repeating: 0, count: size)
        fft.forward(real: &real, imag: &imag)
        fft.inverse(real: &real, imag: &imag)

        for i in 0..<size {
            XCTAssertEqual(real[i], original[i], accuracy: 1e-4, "sample \(i) didn't survive the round trip")
            XCTAssertEqual(imag[i], 0, accuracy: 1e-4)
        }
    }

    /// Real input must produce a conjugate-symmetric spectrum. The separator
    /// relies on this when it mirrors the mask across the Nyquist point.
    func testConjugateSymmetryForRealInput() {
        let size = 256
        let fft = FFT(size: size)
        var real = (0..<size).map { Float(sin(Double($0) * 0.31) + 0.4 * cos(Double($0) * 1.7)) }
        var imag = [Float](repeating: 0, count: size)
        fft.forward(real: &real, imag: &imag)

        for k in 1..<(size / 2) {
            XCTAssertEqual(real[k], real[size - k], accuracy: 1e-3)
            XCTAssertEqual(imag[k], -imag[size - k], accuracy: 1e-3)
        }
    }

    /// Parseval: energy is conserved, up to the transform's N scaling.
    func testEnergyConservation() {
        let size = 512
        let fft = FFT(size: size)
        let original = (0..<size).map { Float(sin(Double($0) * 0.11)) }

        var real = original
        var imag = [Float](repeating: 0, count: size)
        fft.forward(real: &real, imag: &imag)

        let timeEnergy = original.reduce(Float(0)) { $0 + $1 * $1 }
        let spectralEnergy = (0..<size).reduce(Float(0)) { $0 + real[$1] * real[$1] + imag[$1] * imag[$1] }
        XCTAssertEqual(spectralEnergy / Float(size), timeEnergy, accuracy: timeEnergy * 0.001)
    }
}
