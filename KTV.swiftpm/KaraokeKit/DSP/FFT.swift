import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

/// In-place radix-2 complex FFT over split-complex buffers.
///
/// Uses vDSP when Accelerate is present (every Apple platform we ship on) and
/// falls back to a portable Swift implementation elsewhere, which keeps the
/// separator unit-testable on Linux CI. Both paths use the same layout and the
/// same sign convention, so results are interchangeable:
///
///     X[k] = sum(n) x[n] * exp(-2*pi*i*k*n / N)
///
/// The inverse is normalised by `1/N`, so `inverse(forward(x)) == x`.
public final class FFT {
    /// Transform length; always a power of two.
    public let size: Int
    private let log2n: Int

    #if canImport(Accelerate)
    private let setup: FFTSetup
    #else
    private let bitReversal: [Int]
    private let twiddleReal: [Double]
    private let twiddleImag: [Double]
    #endif

    /// - Parameter size: transform length, must be a power of two and >= 2.
    public init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two >= 2")
        self.size = size
        self.log2n = Int(log2(Double(size)).rounded())

        #if canImport(Accelerate)
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP_create_fftsetup failed for size \(size)")
        }
        self.setup = setup
        #else
        var reversal = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var r = 0
            for bit in 0..<log2n where i & (1 << bit) != 0 {
                r |= 1 << (log2n - 1 - bit)
            }
            reversal[i] = r
        }
        self.bitReversal = reversal

        var tr = [Double](repeating: 0, count: size / 2)
        var ti = [Double](repeating: 0, count: size / 2)
        for k in 0..<(size / 2) {
            let angle = -2.0 * Double.pi * Double(k) / Double(size)
            tr[k] = cos(angle)
            ti[k] = sin(angle)
        }
        self.twiddleReal = tr
        self.twiddleImag = ti
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        vDSP_destroy_fftsetup(setup)
        #endif
    }

    /// Forward transform, in place. `real` and `imag` must both hold `size` samples.
    public func forward(real: inout [Float], imag: inout [Float]) {
        transform(real: &real, imag: &imag, inverse: false)
    }

    /// Inverse transform, in place, normalised by `1/size`.
    public func inverse(real: inout [Float], imag: inout [Float]) {
        transform(real: &real, imag: &imag, inverse: true)
    }

    private func transform(real: inout [Float], imag: inout [Float], inverse: Bool) {
        precondition(real.count == size && imag.count == size, "buffers must be \(size) samples")

        #if canImport(Accelerate)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                let direction = inverse ? FFTDirection(kFFTDirection_Inverse)
                                        : FFTDirection(kFFTDirection_Forward)
                vDSP_fft_zip(setup, &split, 1, vDSP_Length(log2n), direction)
                if inverse {
                    // vDSP's inverse is unnormalised; it returns N * x.
                    var scale = Float(1.0 / Double(size))
                    vDSP_vsmul(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1, vDSP_Length(size))
                    vDSP_vsmul(ip.baseAddress!, 1, &scale, ip.baseAddress!, 1, vDSP_Length(size))
                }
            }
        }
        #else
        for i in 0..<size {
            let j = bitReversal[i]
            if j > i {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
        }

        var stride = 2
        while stride <= size {
            let half = stride / 2
            let step = size / stride
            var base = 0
            while base < size {
                var k = 0
                for j in base..<(base + half) {
                    let wr = Float(twiddleReal[k])
                    let wi = Float(inverse ? -twiddleImag[k] : twiddleImag[k])
                    let partner = j + half
                    let tr = real[partner] * wr - imag[partner] * wi
                    let ti = real[partner] * wi + imag[partner] * wr
                    real[partner] = real[j] - tr
                    imag[partner] = imag[j] - ti
                    real[j] += tr
                    imag[j] += ti
                    k += step
                }
                base += stride
            }
            stride <<= 1
        }

        if inverse {
            let scale = Float(1.0 / Double(size))
            for i in 0..<size {
                real[i] *= scale
                imag[i] *= scale
            }
        }
        #endif
    }
}
