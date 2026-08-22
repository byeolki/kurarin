import Foundation
@testable import KurarinDSP

enum Signal {
    static let sampleRate: Float = 48000

    static func sine(frequency: Float, frames: Int, amplitude: Float = 0.5, sampleRate: Float = sampleRate) -> [Float] {
        (0..<frames).map { i in
            amplitude * sinf(2 * .pi * frequency * Float(i) / sampleRate)
        }
    }

    static func silence(frames: Int) -> [Float] {
        [Float](repeating: 0, count: frames)
    }

    /// Deterministic pseudo-random noise so failures reproduce exactly.
    static func noise(frames: Int, amplitude: Float = 0.5, seed: UInt64 = 12345) -> [Float] {
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)
            return (unit * 2 - 1) * amplitude
        }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrtf(sum / Float(samples.count))
    }

    static func rms(_ samples: [Float]) -> Float {
        rms(samples[...])
    }

    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    static func isFinite(_ samples: [Float]) -> Bool {
        samples.allSatisfy { $0.isFinite }
    }

    /// Estimates the dominant frequency by autocorrelation.
    ///
    /// Used to check that the shifter moved pitch by the requested ratio.
    static func dominantFrequency(
        _ samples: [Float],
        sampleRate: Float = sampleRate,
        minimumHz: Float = 50,
        maximumHz: Float = 2000
    ) -> Float? {
        let minLag = Int(sampleRate / maximumHz)
        let maxLag = min(Int(sampleRate / minimumHz), samples.count - 1)
        guard maxLag > minLag else { return nil }

        // Normalised cross-correlation. Dividing by the overlap length instead
        // would inflate the score as the lag grows and make every reading an
        // octave too low.
        var scores = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var product: Float = 0
            var energyA: Float = 0
            var energyB: Float = 0
            for i in 0..<(samples.count - lag) {
                product += samples[i] * samples[i + lag]
                energyA += samples[i] * samples[i]
                energyB += samples[i + lag] * samples[i + lag]
            }
            let denominator = sqrtf(energyA * energyB)
            scores[lag] = denominator > 0 ? product / denominator : 0
        }

        let best = scores[minLag...maxLag].max() ?? 0
        guard best > 0 else { return nil }

        // A periodic signal correlates just as well at every multiple of its
        // period, so take the shortest lag that is essentially as good. Require
        // an actual local maximum: the rising flank into a strong peak also
        // clears the threshold and would report a period that is simply too
        // short.
        for lag in (minLag + 1)..<maxLag
        where scores[lag] >= best * 0.9
            && scores[lag] >= scores[lag - 1]
            && scores[lag] >= scores[lag + 1] {
            return sampleRate / Float(lag)
        }
        return nil
    }
}

/// Runs a unit the way the audio thread does — in fixed blocks — rather than
/// handing it the whole signal at once, which no real callback ever does.
func processStreaming(_ unit: AudioProcessor, _ samples: [Float], blockSize: Int = 256) -> [Float] {
    var output = samples
    output.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let frames = min(blockSize, buffer.count - offset)
            unit.process(base + offset, frameCount: frames)
            offset += frames
        }
    }
    return output
}
