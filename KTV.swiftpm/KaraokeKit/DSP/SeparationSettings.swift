import Foundation

/// Tuning for the centre-channel vocal separator.
///
/// The separator decides, bin by bin, how "centre-panned" the audio is. Lead
/// vocals are almost always mixed dead centre, so a centre-ness mask doubles as
/// a vocal mask. The knobs below trade the two failure modes against each
/// other: push too hard and centre-panned instruments (bass, kick, snare) get
/// scooped out with the voice; back off and more of the voice survives.
public struct SeparationSettings: Equatable, Codable, Sendable {
    /// STFT window length in samples. Must be a power of two.
    ///
    /// 4096 at 44.1 kHz is ~93 ms, which is long enough to resolve the low
    /// harmonics of a male voice without smearing consonants too badly.
    public var fftSize: Int

    /// Raises the phase-coherence term. Higher values demand a tighter match
    /// between the channels before a bin counts as vocal, which preserves the
    /// backing track at the cost of leaving more voice behind.
    public var similarityExponent: Float

    /// Raises the left/right level-balance term. Same trade-off as
    /// `similarityExponent`, but keyed on panning rather than phase.
    public var balanceExponent: Float

    /// Below this frequency the mask is rolled off so the (mono) bass and kick
    /// survive. Vocals carry almost no energy down here anyway.
    public var lowCutHz: Float

    /// Above this frequency the mask is rolled off to keep cymbals and air.
    public var highCutHz: Float

    /// Overall scale on the finished mask, 0...1. `0` is a pass-through (no
    /// removal), `1` applies the mask at full depth.
    public var strength: Float

    public init(
        fftSize: Int = 4096,
        similarityExponent: Float = 2.0,
        balanceExponent: Float = 1.0,
        lowCutHz: Float = 140.0,
        highCutHz: Float = 12_000.0,
        strength: Float = 1.0
    ) {
        self.fftSize = fftSize
        self.similarityExponent = similarityExponent
        self.balanceExponent = balanceExponent
        self.lowCutHz = lowCutHz
        self.highCutHz = highCutHz
        self.strength = strength
    }

    /// Hop between analysis frames: 75% overlap, which is what the Hann
    /// window's overlap-add reconstruction is tuned for.
    public var hopSize: Int { fftSize / 4 }

    /// Leaves more of the backing track intact; more vocal bleed.
    /// Good for dense mixes where scooping the centre is obvious.
    public static let gentle = SeparationSettings(
        similarityExponent: 3.0,
        balanceExponent: 2.0,
        strength: 0.95
    )

    /// The default. Roughly 28 dB of vocal suppression on a typical pop mix.
    public static let balanced = SeparationSettings()

    /// Maximum vocal suppression, at the cost of a noticeably thinner centre.
    public static let aggressive = SeparationSettings(
        similarityExponent: 1.0,
        balanceExponent: 0.5,
        lowCutHz: 110.0,
        highCutHz: 14_000.0
    )

    /// Named presets, in the order the UI should present them.
    public enum Preset: String, CaseIterable, Codable, Sendable {
        case gentle, balanced, aggressive

        public var settings: SeparationSettings {
            switch self {
            case .gentle: return .gentle
            case .balanced: return .balanced
            case .aggressive: return .aggressive
            }
        }

        public var title: String {
            switch self {
            case .gentle: return "Gentle"
            case .balanced: return "Balanced"
            case .aggressive: return "Aggressive"
            }
        }

        public var detail: String {
            switch self {
            case .gentle: return "Keeps the band intact. Some vocal bleeds through."
            case .balanced: return "The usual choice for pop and rock mixes."
            case .aggressive: return "Strongest removal. Can thin out bass and drums."
            }
        }
    }
}
