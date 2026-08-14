import Foundation

/// Freeverb-style reverberator: parallel comb filters into series allpasses.
///
/// Mono only — the chain runs mono up to the point where it is duplicated for
/// the virtual device, and a stereo tail would be thrown away.
public final class Reverb: AudioProcessor {
    /// Tail length, 0 to just under 1.
    public var roomSize: Float = 0.5
    /// High frequency absorption, 0 to 1.
    public var damping: Float = 0.5
    /// Dry/wet blend.
    public var mix: Float = 0

    private static let combTuning = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTuning = [556, 441, 341, 225]

    private final class Comb {
        var buffer: [Float]
        var index = 0
        var filterStore: Float = 0

        init(size: Int) { buffer = [Float](repeating: 0, count: size) }

        func process(_ input: Float, feedback: Float, damping: Float) -> Float {
            let output = buffer[index]
            filterStore = output * (1 - damping) + filterStore * damping
            buffer[index] = input + filterStore * feedback
            index = (index + 1) % buffer.count
            return output
        }

        func reset() {
            for i in buffer.indices { buffer[i] = 0 }
            filterStore = 0
            index = 0
        }
    }

    private final class Allpass {
        var buffer: [Float]
        var index = 0

        init(size: Int) { buffer = [Float](repeating: 0, count: size) }

        func process(_ input: Float, feedback: Float) -> Float {
            let stored = buffer[index]
            let output = -input + stored
            buffer[index] = input + stored * feedback
            index = (index + 1) % buffer.count
            return output
        }

        func reset() {
            for i in buffer.indices { buffer[i] = 0 }
            index = 0
        }
    }

    private let combs: [Comb]
    private let allpasses: [Allpass]

    public init(sampleRate: Float) {
        // The tunings above are quoted for 44.1 kHz; scale so the room keeps
        // its character at other rates.
        let scale = sampleRate / 44100
        combs = Reverb.combTuning.map { Comb(size: max(1, Int(Float($0) * scale))) }
        allpasses = Reverb.allpassTuning.map { Allpass(size: max(1, Int(Float($0) * scale))) }
    }

    public func reset() {
        combs.forEach { $0.reset() }
        allpasses.forEach { $0.reset() }
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let blend = min(max(mix, 0), 1)
        guard blend > 0.0001 else { return }

        let feedback = min(max(roomSize, 0), 0.98) * 0.28 + 0.7
        let damp = min(max(damping, 0), 1) * 0.4
        let inputGain: Float = 0.015

        for i in 0..<frameCount {
            let dry = buffer[i]
            let input = dry * inputGain

            var wet: Float = 0
            for comb in combs {
                wet += comb.process(input, feedback: feedback, damping: damp)
            }
            for allpass in allpasses {
                wet = allpass.process(wet, feedback: 0.5)
            }

            buffer[i] = dry + (wet - dry) * blend
        }
    }
}
