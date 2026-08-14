import Foundation

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

        var bestLag = -1
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            var score: Float = 0
            for i in 0..<(samples.count - lag) {
                score += samples[i] * samples[i + lag]
            }
            score /= Float(samples.count - lag)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestLag > 0 else { return nil }
        return sampleRate / Float(bestLag)
    }
}
