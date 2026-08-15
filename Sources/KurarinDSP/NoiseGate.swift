import Foundation

/// Envelope gate with hysteresis and a hold time.
///
/// Two thresholds instead of one: the gate opens at `thresholdDB` but does not
/// close until the signal falls `hysteresisDB` below it. A single threshold
/// makes the gate chatter on breath and room tone sitting right at the
/// boundary, which is far more distracting than the noise it removes.
public final class NoiseGate: AudioProcessor {
    public var thresholdDB: Float = -45
    public var hysteresisDB: Float = 6
    public var attackMs: Float = 2
    public var releaseMs: Float = 120
    public var holdMs: Float = 40
    public var enabled: Bool = true

    private let sampleRate: Float
    /// Readable inside the module because the output cannot show them: the gate
    /// only multiplies, and a gain stuck at the smallest denormal times any
    /// signal underflows to a clean zero. The only way to tell a gate that has
    /// reached silence from one that is stalled in the denormal range is to
    /// look at the state itself.
    private(set) var envelope: Float = 0
    private(set) var gain: Float = 0
    private var holdCounter: Int = 0
    private var isOpen = false

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    public func reset() {
        envelope = 0
        gain = 0
        holdCounter = 0
        isOpen = false
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard enabled else { return }

        let openLevel = powf(10, thresholdDB / 20)
        let closeLevel = powf(10, (thresholdDB - hysteresisDB) / 20)
        let attackCoefficient = coefficient(forMilliseconds: attackMs)
        let releaseCoefficient = coefficient(forMilliseconds: releaseMs)
        let holdSamples = Int(holdMs * 0.001 * sampleRate)
        // Envelope follower tracks peaks quickly and decays over roughly 10 ms.
        let envelopeDecay = coefficient(forMilliseconds: 10)

        for i in 0..<frameCount {
            let magnitude = abs(buffer[i])
            envelope = magnitude > envelope
                ? magnitude
                : envelope * envelopeDecay + magnitude * (1 - envelopeDecay)

            if isOpen {
                if envelope < closeLevel {
                    if holdCounter > 0 {
                        holdCounter -= 1
                    } else {
                        isOpen = false
                    }
                } else {
                    holdCounter = holdSamples
                }
            } else if envelope > openLevel {
                isOpen = true
                holdCounter = holdSamples
            }

            let target: Float = isOpen ? 1 : 0
            let coefficient = target > gain ? attackCoefficient : releaseCoefficient
            gain = target + (gain - target) * coefficient

            buffer[i] *= gain
        }

        // Both of these approach zero exponentially while the gate is shut,
        // which is most of the time in a quiet room. Left alone they spend the
        // silence in the denormal range, where the arithmetic costs orders of
        // magnitude more than it does here.
        envelope = withoutDenormals(envelope)
        gain = withoutDenormals(gain)
    }

    private func coefficient(forMilliseconds ms: Float) -> Float {
        guard ms > 0 else { return 0 }
        return expf(-1 / (ms * 0.001 * sampleRate))
    }
}
