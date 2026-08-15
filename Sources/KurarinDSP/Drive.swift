import Foundation

/// Saturation, bit depth reduction and sample rate reduction.
///
/// Three separate flavours of grit rather than one "distortion" knob, because
/// the presets want different things: a radio voice wants saturation and a
/// bandpass, a robot wants sample rate reduction, a monster wants both.
public final class Drive: AudioProcessor {
    /// Pre-gain into the saturator. 1 leaves the signal untouched.
    public var amount: Float = 1
    /// Quantisation depth. 0 disables bit crushing.
    public var bitDepth: Float = 0
    /// Effective sample rate for the sample-and-hold stage. 0 disables it.
    public var downsampleHz: Float = 0
    /// Dry/wet blend of the saturated signal.
    public var mix: Float = 1

    private let sampleRate: Float
    private var holdValue: Float = 0
    private var holdPhase: Float = 0

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    public func reset() {
        holdValue = 0
        holdPhase = 0
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let saturating = amount > 1.001
        let crushing = bitDepth >= 1
        let downsampling = downsampleHz > 0 && downsampleHz < sampleRate
        guard saturating || crushing || downsampling else { return }

        let levels = crushing ? powf(2, bitDepth) : 0
        let phaseIncrement = downsampling ? downsampleHz / sampleRate : 0
        let blend = min(max(mix, 0), 1)
        // tanh compresses towards ±1; dividing by tanh(amount) keeps the loudest
        // input mapping back to full scale so drive does not double as a fader.
        let normalisation = saturating ? 1 / tanhf(amount) : 1

        for i in 0..<frameCount {
            let dry = buffer[i]
            var wet = dry

            if downsampling {
                holdPhase += phaseIncrement
                if holdPhase >= 1 {
                    holdPhase -= floor(holdPhase)
                    holdValue = wet
                }
                wet = holdValue
            }

            if saturating {
                wet = tanhf(wet * amount) * normalisation
            }

            if crushing {
                wet = (wet * levels).rounded() / levels
            }

            buffer[i] = dry + (wet - dry) * blend
        }
    }
}
