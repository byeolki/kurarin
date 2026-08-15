import XCTest
@testable import KurarinDSP

/// The limiter's sliding-window maximum is kept as a monotonic queue rather
/// than rescanned per sample. That is a worthwhile saving only if it is exactly
/// the same limiter afterwards, so it is checked against the straightforward
/// version rather than against a description of what it should do.
final class LimiterWindowTests: XCTestCase {
    /// The obvious implementation: rescan the whole look-ahead window for every
    /// sample. Deliberately naive, and deliberately identical in every other
    /// respect — same order of operations, so agreement can be exact.
    private final class ReferenceLimiter {
        var ceilingDB: Float = -0.5
        var releaseMs: Float = 60

        private let sampleRate: Float
        private let lookaheadFrames: Int
        private var delayLine: [Float]
        private var peakWindow: [Float]
        private var writeIndex = 0
        private var gain: Float = 1

        init(sampleRate: Float, lookaheadMs: Float = 2) {
            self.sampleRate = sampleRate
            self.lookaheadFrames = max(1, Int(lookaheadMs * 0.001 * sampleRate))
            self.delayLine = [Float](repeating: 0, count: lookaheadFrames)
            self.peakWindow = [Float](repeating: 0, count: lookaheadFrames)
        }

        func process(_ samples: [Float]) -> [Float] {
            let ceiling = powf(10, ceilingDB / 20)
            let releaseCoefficient = releaseMs > 0
                ? expf(-1 / (releaseMs * 0.001 * sampleRate))
                : 0

            var output = samples
            for i in output.indices {
                let input = output[i]

                let delayed = delayLine[writeIndex]
                delayLine[writeIndex] = input
                peakWindow[writeIndex] = abs(input)

                var windowPeak: Float = 0
                for value in peakWindow where value > windowPeak {
                    windowPeak = value
                }

                let requiredGain = windowPeak > ceiling ? ceiling / windowPeak : 1
                if requiredGain < gain {
                    gain = requiredGain
                } else {
                    gain = requiredGain + (gain - requiredGain) * releaseCoefficient
                }

                output[i] = delayed * gain
                writeIndex = (writeIndex + 1) % delayLine.count
            }
            return output
        }
    }

    private func assertMatchesReference(
        _ input: [Float],
        blockSize: Int = 256,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let limiter = Limiter(sampleRate: Signal.sampleRate)
        let reference = ReferenceLimiter(sampleRate: Signal.sampleRate)

        let actual = processStreaming(limiter, input, blockSize: blockSize)
        let expected = reference.process(input)

        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() where pair.0 != pair.1 {
            XCTFail(
                "sample \(index): \(pair.0) but the plain version says \(pair.1)",
                file: file, line: line
            )
            return
        }
    }

    func testMatchesTheNaiveVersionOnNoise() {
        assertMatchesReference(Signal.noise(frames: 48000, amplitude: 0.9))
    }

    /// A steady tone below the ceiling never engages the limiter, so this
    /// checks the queue keeps reporting the right maximum while doing nothing.
    func testMatchesTheNaiveVersionOnAQuietTone() {
        assertMatchesReference(Signal.sine(frequency: 220, frames: 24000, amplitude: 0.2))
    }

    /// Isolated spikes with silence between them are the case a rolling maximum
    /// gets wrong: the peak has to leave the window at exactly the right sample.
    func testMatchesTheNaiveVersionOnSparseSpikes() {
        var samples = [Float](repeating: 0, count: 24000)
        for (index, position) in stride(from: 100, to: 24000, by: 731).enumerated() {
            samples[position] = index.isMultiple(of: 2) ? 1.8 : -1.4
        }
        assertMatchesReference(samples)
    }

    /// A descending staircase leaves the queue holding several entries at once,
    /// which is where an off-by-one in the retirement check would show up.
    func testMatchesTheNaiveVersionOnADecayingStaircase() {
        var samples = [Float](repeating: 0, count: 12000)
        var level: Float = 1.9
        for i in samples.indices {
            if i % 37 == 0 { level *= 0.97 }
            samples[i] = level
        }
        assertMatchesReference(samples)
    }

    /// Block boundaries must not disturb the window: the host picks the size.
    func testMatchesTheNaiveVersionAcrossOddBlockSizes() {
        assertMatchesReference(Signal.noise(frames: 24000, amplitude: 1.5), blockSize: 37)
        assertMatchesReference(Signal.noise(frames: 24000, amplitude: 1.5, seed: 99), blockSize: 1)
    }
}
