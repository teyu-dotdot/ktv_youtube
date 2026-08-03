import Foundation

/// Analysis/synthesis windows for the STFT.
public enum HannWindow {
    /// Periodic (DFT-even) Hann window: `0.5 - 0.5*cos(2*pi*n/N)`.
    ///
    /// The periodic form — rather than the symmetric one — is what satisfies
    /// constant-overlap-add at 75% overlap, which is the hop the separator uses.
    public static func periodic(length: Int) -> [Float] {
        precondition(length > 0)
        var window = [Float](repeating: 0, count: length)
        let scale = 2.0 * Double.pi / Double(length)
        for i in 0..<length {
            window[i] = Float(0.5 - 0.5 * cos(scale * Double(i)))
        }
        return window
    }

    /// Sum of squared window values at each output sample for a given hop.
    ///
    /// Exposed for tests: weighted overlap-add divides by this, and it must be
    /// non-zero and near-constant across the steady-state region.
    public static func squaredOverlapSum(length: Int, hop: Int, frames: Int) -> [Float] {
        let window = periodic(length: length)
        var sum = [Float](repeating: 0, count: (frames - 1) * hop + length)
        for frame in 0..<frames {
            let start = frame * hop
            for i in 0..<length {
                sum[start + i] += window[i] * window[i]
            }
        }
        return sum
    }
}
