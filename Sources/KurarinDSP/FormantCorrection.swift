import Foundation

/// Corrects for the fact that a vocal tract does not scale uniformly.
///
/// The shifter moves formants by resampling each grain, which multiplies every
/// frequency by the same number. Real anatomy does not work that way. A shorter
/// tract raises the higher resonances more than the lower ones — the pharynx
/// and the oral cavity differ in how much they shrink between an adult and a
/// child, or between a man and a woman — so F1 moves by rather less than the
/// ratio and F3 and F4 by rather more. The literature on voice conversion
/// handles this with a piecewise-linear or cepstral frequency map; doing that
/// properly needs a spectrum, and a spectrum needs an FFT window this chain
/// cannot afford.
///
/// What can be afforded is the difference between the two maps, applied as a
/// gentle tilt: with the whole spectrum already moved uniformly, pull the
/// bottom back down a little and push the top a little further. It is an
/// approximation of a warp by an equaliser, which is not the same thing — but
/// the error is a decibel or two of level across a band, where the alternative
/// is a formant sitting several hundred hertz away from where an ear expects
/// to find it.
///
/// Derived from the ratio rather than left to each preset: it is a fact about
/// vocal tracts, not a matter of taste, and a preset that forgets it sounds
/// like a machine whatever else it gets right.
struct FormantCorrection {
    /// The shelves that turn a uniform scaling into something closer to the
    /// non-uniform one anatomy produces.
    ///
    /// Both are no-ops at a ratio of 1, and both grow with the distance from
    /// it, in the direction that undoes the uniform map's error.
    static func shelves(forRatio ratio: Float) -> (low: Biquad.Kind, lowGainDB: Float, highGainDB: Float) {
        // How far from "no change", in octaves, signed.
        let octaves = log2(max(ratio, 0.01))
        // Six decibels an octave is what lines the corrected first formant up
        // with the measured male-to-female maps in the literature without the
        // vowel starting to sound thin.
        let lowGain = -4.5 * octaves
        let highGain = 2.5 * octaves
        return (.lowShelf, lowGain, highGain)
    }

    static let lowShelfHz: Float = 700
    static let highShelfHz: Float = 3200
}

/// Applies the correction as two shelving filters.
public final class FormantCorrector: AudioProcessor {
    /// The ratio the shifter is using. 1 leaves the signal untouched.
    public var ratio: Float = 1 {
        didSet {
            guard abs(ratio - configured) > 0.005 else { return }
            configure()
        }
    }

    /// 0 disables the correction, for anyone who prefers the plain scaling.
    public var amount: Float = 1 {
        didSet {
            guard abs(amount - configuredAmount) > 0.005 else { return }
            configure()
        }
    }

    private let low: Biquad
    private let high: Biquad
    private var configured: Float = 1
    private var configuredAmount: Float = 1
    private var active = false

    public init(sampleRate: Float) {
        low = Biquad(sampleRate: sampleRate)
        high = Biquad(sampleRate: sampleRate)
        configure()
    }

    private func configure() {
        configured = ratio
        configuredAmount = amount

        let shelves = FormantCorrection.shelves(forRatio: ratio)
        let lowGain = shelves.lowGainDB * amount
        let highGain = shelves.highGainDB * amount
        active = abs(lowGain) > 0.05 || abs(highGain) > 0.05

        low.configure(
            kind: .lowShelf,
            frequency: FormantCorrection.lowShelfHz,
            q: 0.707,
            gainDB: lowGain
        )
        high.configure(
            kind: .highShelf,
            frequency: FormantCorrection.highShelfHz,
            q: 0.707,
            gainDB: highGain
        )
    }

    public func reset() {
        low.reset()
        high.reset()
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard active else { return }
        low.process(buffer, frameCount: frameCount)
        high.process(buffer, frameCount: frameCount)
    }
}
