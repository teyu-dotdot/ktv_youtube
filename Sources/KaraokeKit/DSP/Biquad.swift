import Foundation

/// Direct-form-I biquad section.
public struct Biquad: Equatable, Sendable {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

    /// Runs the section over a signal, starting from rest.
    public func process(_ input: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<input.count {
            let x0 = input[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            output[i] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return output
    }

    /// RBJ cookbook band-pass, constant 0 dB peak gain.
    public static func bandPass(centerHz: Float, q: Float, sampleRate: Double) -> Biquad {
        let omega = 2 * Float.pi * centerHz / Float(sampleRate)
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * max(q, 0.001))

        let a0 = 1 + alpha
        return Biquad(
            b0: alpha / a0,
            b1: 0,
            b2: -alpha / a0,
            a1: -2 * cosOmega / a0,
            a2: (1 - alpha) / a0
        )
    }
}

/// The mono fallback's crude "where the voice probably is" filter.
///
/// Three overlapping band-passes spanning the fundamental and first formants of
/// a sung voice. This is a blunt instrument — it cannot tell a voice from a
/// guitar in the same range — and exists only so mono sources degrade to
/// something rather than nothing.
struct MonoVocalNotch {
    let sections: [Biquad]

    init(sampleRate: Double) {
        let nyquist = Float(sampleRate / 2)
        let centers: [(Float, Float)] = [(300, 0.9), (900, 0.8), (2600, 0.9)]
        sections = centers
            .filter { $0.0 < nyquist * 0.9 }
            .map { Biquad.bandPass(centerHz: $0.0, q: $0.1, sampleRate: sampleRate) }
    }

    /// Sums the sections in *parallel*. Cascading them would multiply three
    /// narrow responses together and pass almost nothing.
    func process(_ input: [Float]) -> [Float] {
        guard !sections.isEmpty else { return [Float](repeating: 0, count: input.count) }
        var output = [Float](repeating: 0, count: input.count)
        for section in sections {
            let band = section.process(input)
            for i in 0..<output.count {
                output[i] += band[i]
            }
        }
        let scale = 1 / Float(sections.count)
        for i in 0..<output.count {
            output[i] *= scale
        }
        return output
    }
}
