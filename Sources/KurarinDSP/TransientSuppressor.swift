import Foundation

/// Removes mouse clicks, key presses and desk thumps without eating the voice.
///
/// These noises have nothing in common with each other acoustically except the
/// shape of their envelope: they arrive far faster than a voice can, and they
/// are over within a few milliseconds. So the detector does not look at
/// frequency at all — it compares a fast envelope against a slow one, and a
/// jump of more than a few decibels in a millisecond is something a vocal tract
/// cannot produce.
///
/// The reason ordinary noise suppression chews up a held "aaah" is that it
/// decides what to remove from level alone, and a steady vowel that starts
/// after a quiet passage looks like an onset. This one is told, per block,
/// whether the signal is voiced. A voiced frame is periodic — vowels are, key
/// presses are not — and while it is voiced the detector is deliberately made
/// hard of hearing: the threshold rises and the ducking shallows, so a sustained
/// note is left alone even as it swells.
///
/// A duck that starts when the click has already been heard is useless, so the
/// signal is delayed by a few milliseconds and the gain reduction is applied to
/// audio that has not been emitted yet — the same trick as the limiter, for the
/// same reason.
public final class TransientSuppressor: AudioProcessor {
    /// 0 leaves the signal alone; 1 ducks hard on anything sudden.
    public var strength: Float = 0
    /// Set once per block from the shared pitch tracker. The whole difference
    /// between this and a level gate.
    public var isVoiced: Bool = false

    public let lookaheadFrames: Int

    private let sampleRate: Float
    private var delayLine: [Float]
    private var writeIndex = 0

    /// Three time scales. The fast one sees the attack; the medium one is what
    /// the voice itself is doing right now, which is the only fair thing to
    /// compare an attack against; the slow one is the room, used as a floor so
    /// that near-silence does not make every sound look sudden.
    private var fastEnvelope: Float = 0
    private var mediumEnvelope: Float = 0
    private var slowEnvelope: Float = 0
    private var gain: Float = 1
    private var holdCounter = 0
    /// How long the signal has been sitting above the threshold. A click is
    /// over in a couple of milliseconds; anything still loud after that is a
    /// sound the speaker is making on purpose.
    private var elevatedSamples = 0
    private var quietSamples = 0
    /// Set when a duck turns out to have been aimed at a voice. Recovery from a
    /// mistake should be quick — the sound being restored is one the listener
    /// is waiting for — while recovery after a real click can afford to be
    /// gentle, because there is nothing underneath it to restore.
    private var misfire = false

    public init(sampleRate: Float, lookaheadMs: Float = 4) {
        self.sampleRate = sampleRate
        self.lookaheadFrames = max(1, Int(lookaheadMs * 0.001 * sampleRate))
        self.delayLine = [Float](repeating: 0, count: lookaheadFrames)
    }

    public func reset() {
        for i in delayLine.indices { delayLine[i] = 0 }
        writeIndex = 0
        fastEnvelope = 0
        mediumEnvelope = 0
        slowEnvelope = 0
        gain = 1
        holdCounter = 0
        elevatedSamples = 0
        quietSamples = 0
        misfire = false
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let amount = min(max(strength, 0), 1)
        guard amount > 0.001 else {
            // Still has to run the delay line: a unit that stops delaying
            // mid-stream jumps the output forward by its own latency.
            passThrough(buffer, frameCount: frameCount)
            return
        }

        let fastCoefficient = coefficient(forMilliseconds: 1)
        let mediumCoefficient = coefficient(forMilliseconds: 15)
        let slowCoefficient = coefficient(forMilliseconds: 200)
        let holdSamples = Int(0.010 * sampleRate)
        // Past this, whatever it is, it is not a click.
        let sustainedLimit = Int(0.010 * sampleRate)
        // Long enough to cross the gap between glottal pulses of even a deep
        // voice, short enough that two separate clicks are still two events.
        let bridgeSamples = Int(0.020 * sampleRate)

        // Measured against what the voice is doing right now rather than
        // against the room: a knock is only a little louder than a shout in
        // absolute terms, but it gets there in a fraction of the time.
        // Voicing asks for more before acting, because ducking is audible
        // against a held note and consonants are transients too.
        let ratioThreshold: Float = isVoiced ? 4.5 : 3.5
        // How far down a detected transient is pushed. Shallower while voiced,
        // where the cure is more audible than the disease.
        let depth = (isVoiced ? 0.6 : 1) * amount
        let duckGain = 1 - 0.95 * depth
        let releaseCoefficient = coefficient(forMilliseconds: 40)
        let recoveryCoefficient = coefficient(forMilliseconds: 4)

        delayLine.withUnsafeMutableBufferPointer { delay in
            for i in 0..<frameCount {
                let input = buffer[i]
                let delayed = delay[writeIndex]
                delay[writeIndex] = input
                writeIndex = (writeIndex + 1) % delay.count

                let magnitude = abs(input)
                fastEnvelope = magnitude > fastEnvelope
                    ? magnitude
                    : fastEnvelope * fastCoefficient + magnitude * (1 - fastCoefficient)
                // The medium and slow followers deliberately do not jump to a
                // peak: they are the thing being compared against, and a
                // reference that leaps with the click would hide it.
                mediumEnvelope += (magnitude - mediumEnvelope) * (1 - mediumCoefficient)
                slowEnvelope += (magnitude - slowEnvelope) * (1 - slowCoefficient)

                // A floor on the reference: against digital silence every
                // sound is infinitely sudden, and the first word after a
                // pause is not a click.
                let reference = max(mediumEnvelope, slowEnvelope, 0.0015)
                let above = fastEnvelope > reference * ratioThreshold
                quietSamples = above ? 0 : quietSamples + 1

                // A dip is not the end of a sound. Voiced speech is a train of
                // pulses with gaps between them, and a gap is longer than the
                // click being looked for — so the count keeps running across a
                // short quiet stretch and only a real silence resets it.
                // Without this bridge, every glottal pulse of a held vowel
                // looks like a fresh transient and the note is ducked over and
                // over.
                if above || quietSamples <= bridgeSamples {
                    elevatedSamples += 1
                } else {
                    elevatedSamples = 0
                }

                if above && elevatedSamples <= sustainedLimit {
                    holdCounter = holdSamples
                } else if elevatedSamples > sustainedLimit && holdCounter > 0 {
                    // Gone on too long to be a click: a vowel swelling, a word
                    // starting, a note being held. Let go rather than strangle
                    // it — and let go quickly, because what is being restored
                    // is something the listener is waiting to hear.
                    holdCounter = 0
                    misfire = true
                }

                let target: Float
                if holdCounter > 0 {
                    holdCounter -= 1
                    target = duckGain
                } else {
                    target = 1
                }

                // Instant downwards, gentle upwards: the peak being ducked has
                // not left the delay line yet, so there is no need to ease into
                // it, while easing out avoids a click of its own.
                if target < gain {
                    gain = target
                } else {
                    gain = target + (gain - target) * (misfire ? recoveryCoefficient : releaseCoefficient)
                    if gain > 0.999 { misfire = false }
                }

                buffer[i] = delayed * gain
            }
        }

        fastEnvelope = withoutDenormals(fastEnvelope)
        mediumEnvelope = withoutDenormals(mediumEnvelope)
        slowEnvelope = withoutDenormals(slowEnvelope)
        gain = withoutDenormals(gain)
    }

    private func passThrough(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        delayLine.withUnsafeMutableBufferPointer { delay in
            for i in 0..<frameCount {
                let input = buffer[i]
                buffer[i] = delay[writeIndex]
                delay[writeIndex] = input
                writeIndex = (writeIndex + 1) % delay.count
            }
        }
        gain = 1
        holdCounter = 0
    }

    private func coefficient(forMilliseconds ms: Float) -> Float {
        guard ms > 0 else { return 0 }
        return expf(-1 / (ms * 0.001 * sampleRate))
    }
}
