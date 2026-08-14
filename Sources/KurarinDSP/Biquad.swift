import Foundation

/// Second-order IIR section in transposed direct form II.
///
/// Coefficients follow the Audio EQ Cookbook. The transposed form is used
/// because it keeps its state in the same units as the signal, which makes it
/// better behaved numerically at the low corner frequencies used by the rumble
/// filter.
public final class Biquad: AudioProcessor {
    public enum Kind: Sendable {
        case lowpass
        case highpass
        case peaking
        case lowShelf
        case highShelf
    }

    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    private let sampleRate: Float

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    /// - Parameters:
    ///   - frequency: corner or centre frequency in hertz
    ///   - q: resonance; 0.707 gives a maximally flat response
    ///   - gainDB: only used by the peaking and shelving kinds
    public func configure(kind: Kind, frequency: Float, q: Float, gainDB: Float = 0) {
        let nyquist = sampleRate * 0.5
        let f = min(max(frequency, 1), nyquist * 0.99)
        let safeQ = max(q, 0.0001)

        let omega = 2 * Float.pi * f / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * safeQ)
        let a = pow(10, gainDB / 40)

        var nb0: Float, nb1: Float, nb2: Float
        var na0: Float, na1: Float, na2: Float

        switch kind {
        case .lowpass:
            nb0 = (1 - cosOmega) / 2
            nb1 = 1 - cosOmega
            nb2 = (1 - cosOmega) / 2
            na0 = 1 + alpha
            na1 = -2 * cosOmega
            na2 = 1 - alpha

        case .highpass:
            nb0 = (1 + cosOmega) / 2
            nb1 = -(1 + cosOmega)
            nb2 = (1 + cosOmega) / 2
            na0 = 1 + alpha
            na1 = -2 * cosOmega
            na2 = 1 - alpha

        case .peaking:
            nb0 = 1 + alpha * a
            nb1 = -2 * cosOmega
            nb2 = 1 - alpha * a
            na0 = 1 + alpha / a
            na1 = -2 * cosOmega
            na2 = 1 - alpha / a

        case .lowShelf:
            let sqrtA = sqrt(a)
            let twoSqrtAAlpha = 2 * sqrtA * alpha
            nb0 = a * ((a + 1) - (a - 1) * cosOmega + twoSqrtAAlpha)
            nb1 = 2 * a * ((a - 1) - (a + 1) * cosOmega)
            nb2 = a * ((a + 1) - (a - 1) * cosOmega - twoSqrtAAlpha)
            na0 = (a + 1) + (a - 1) * cosOmega + twoSqrtAAlpha
            na1 = -2 * ((a - 1) + (a + 1) * cosOmega)
            na2 = (a + 1) + (a - 1) * cosOmega - twoSqrtAAlpha

        case .highShelf:
            let sqrtA = sqrt(a)
            let twoSqrtAAlpha = 2 * sqrtA * alpha
            nb0 = a * ((a + 1) + (a - 1) * cosOmega + twoSqrtAAlpha)
            nb1 = -2 * a * ((a - 1) + (a + 1) * cosOmega)
            nb2 = a * ((a + 1) + (a - 1) * cosOmega - twoSqrtAAlpha)
            na0 = (a + 1) - (a - 1) * cosOmega + twoSqrtAAlpha
            na1 = 2 * ((a - 1) - (a + 1) * cosOmega)
            na2 = (a + 1) - (a - 1) * cosOmega - twoSqrtAAlpha
        }

        b0 = nb0 / na0
        b1 = nb1 / na0
        b2 = nb2 / na0
        a1 = na1 / na0
        a2 = na2 / na0
    }

    public func reset() {
        z1 = 0
        z2 = 0
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        var s1 = z1
        var s2 = z2
        for i in 0..<frameCount {
            let x = buffer[i]
            let y = b0 * x + s1
            s1 = b1 * x - a1 * y + s2
            s2 = b2 * x - a2 * y
            buffer[i] = y
        }
        // Denormals decay to zero here rather than costing cycles for minutes
        // after a signal stops.
        z1 = s1.isNormal || s1 == 0 ? s1 : 0
        z2 = s2.isNormal || s2 == 0 ? s2 : 0
    }
}
