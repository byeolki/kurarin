import Foundation

/// Adds the aspiration noise a voice has and a pitch shifter throws away.
///
/// A glottis does not close completely on every cycle, and the air that keeps
/// escaping is heard as breath: a quiet band of noise sitting on top of the
/// harmonics, strongest above about two kilohertz. How much of it there is is
/// one of the cues a listener uses to judge who is speaking — female voices
/// carry noticeably more of it than male ones, which is why raising pitch and
/// formants alone produces something that sounds processed rather than like a
/// different person.
///
/// PSOLA cannot supply it. It moves periodic content by repeating glottal
/// periods, and repeating a period repeats whatever noise was in it, which
/// turns breath into a buzz at the new pitch. So the breath is left out of the
/// shifter and put back here, as fresh noise, shaped by the envelope of the
/// voice so that it starts and stops with it.
public final class BreathGenerator: AudioProcessor {
    /// 0 adds nothing. Around 0.3 is a noticeably breathy voice.
    public var amount: Float = 0
    /// Aspiration accompanies voicing. A fricative is already noise, and adding
    /// more only makes it hiss.
    public var isVoiced: Bool = false

    private let sampleRate: Float
    private let highPass: Biquad
    private let lowPass: Biquad
    private var envelope: Float = 0
    private var voicedBlend: Float = 0
    private var random: UInt64 = 0x2545F4914F6CDD1D
    /// The noise is built and filtered separately before it is mixed in.
    /// Filtering after the mix would band-limit the voice along with it.
    private var scratch: [Float]
    private static let maximumBlock = 8192

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
        scratch = [Float](repeating: 0, count: BreathGenerator.maximumBlock)
        highPass = Biquad(sampleRate: sampleRate)
        lowPass = Biquad(sampleRate: sampleRate)
        // The band where breath lives. Below this it muddies the vowel; above
        // it, it is just hiss.
        highPass.configure(kind: .highpass, frequency: 2200, q: 0.707)
        // Stops below the split, where the high band shaper takes over. Two
        // units adding noise to the same octave is how a voice ends up sounding
        // like a hiss with words in it.
        lowPass.configure(kind: .lowpass, frequency: 4800, q: 0.707)
    }

    public func reset() {
        highPass.reset()
        lowPass.reset()
        envelope = 0
        voicedBlend = 0
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard amount > 0.001 else {
            // The envelope still has to follow the signal, or the first breath
            // after switching it on arrives at whatever level it left off at.
            let release = releaseCoefficient
            for i in 0..<frameCount { follow(abs(buffer[i]), release: release) }
            envelope = withoutDenormals(envelope)
            return
        }

        var offset = 0
        while offset < frameCount {
            let chunk = min(frameCount - offset, BreathGenerator.maximumBlock)
            fillNoise(from: buffer + offset, count: chunk)

            scratch.withUnsafeMutableBufferPointer { noise in
                guard let base = noise.baseAddress else { return }
                highPass.process(base, frameCount: chunk)
                lowPass.process(base, frameCount: chunk)
                for i in 0..<chunk {
                    buffer[offset + i] += base[i]
                }
            }
            offset += chunk
        }

        envelope = withoutDenormals(envelope)
        voicedBlend = withoutDenormals(voicedBlend)
    }

    /// Builds one block of breath: white noise scaled by the envelope of the
    /// voice, so that it swells and stops with it rather than sitting
    /// underneath as a constant hiss.
    private func fillNoise(from signal: UnsafePointer<Float>, count: Int) {
        // Voicing is a per-block verdict, and stepping the level at a block
        // boundary would be heard as a click.
        let voicedTarget: Float = isVoiced ? 1 : 0
        let blendCoefficient = expf(-1 / (0.02 * sampleRate))

        scratch.withUnsafeMutableBufferPointer { noise in
            guard let base = noise.baseAddress else { return }
            let release = releaseCoefficient
            for i in 0..<count {
                follow(abs(signal[i]), release: release)
                voicedBlend = voicedTarget + (voicedBlend - voicedTarget) * blendCoefficient

                random = random &* 6364136223846793005 &+ 1442695040888963407
                let white = Float(Int32(truncatingIfNeeded: random >> 32)) / Float(Int32.max)
                // Aspiration in a real voice sits around thirty decibels below
                // the vowel it accompanies. At nine tenths of the envelope this
                // was landing eleven decibels below it — not breath, a hiss
                // with a voice behind it.
                base[i] = white * envelope * voicedBlend * amount * 0.09
            }
        }
    }

    /// Hoisted out of the per-sample path: an exponential per sample, for a
    /// constant, is a surprising amount of the cost of a unit this simple.
    private lazy var releaseCoefficient = expf(-1 / (0.06 * sampleRate))

    private func follow(_ magnitude: Float, release: Float) {
        // Fast up, slow down: breath tracks the syllable, not the waveform.
        let attack: Float = 0.3
        envelope = magnitude > envelope
            ? envelope + (magnitude - envelope) * attack
            : envelope * release
    }
}
