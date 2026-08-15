import XCTest
@testable import KurarinDSP

/// Cases the steady-tone tests next to the shifter do not reach: a signal with
/// the harmonic structure that makes naive estimators drop an octave, and the
/// buffering behaviour underneath the estimate.
final class PitchTrackerBufferingTests: XCTestCase {
    private func track(
        _ samples: [Float],
        minimumHz: Float = 60,
        blockSize: Int = 512
    ) -> PitchTracker {
        let tracker = PitchTracker(sampleRate: Signal.sampleRate, minimumHz: minimumHz)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset + blockSize <= buffer.count {
                tracker.push(base + offset, frameCount: blockSize)
                tracker.analyse()
                offset += blockSize
            }
        }
        return tracker
    }

    /// A tone with strong harmonics is where a plain difference function picks
    /// the octave below the truth. The cumulative mean normalisation is what
    /// prevents that, and a voice is never a bare sine.
    func testDoesNotDropAnOctaveOnAHarmonicRichTone() {
        let fundamental: Float = 110
        let frames = 24000
        var samples = Signal.sine(frequency: fundamental, frames: frames, amplitude: 0.4)
        for harmonic in 2...6 {
            let overtone = Signal.sine(
                frequency: fundamental * Float(harmonic),
                frames: frames,
                amplitude: 0.4 / Float(harmonic)
            )
            for i in 0..<frames { samples[i] += overtone[i] }
        }

        let tracker = track(samples)

        XCTAssertTrue(tracker.isVoiced)
        XCTAssertEqual(Signal.sampleRate / tracker.periodSamples, fundamental, accuracy: 4)
    }

    /// The history is compacted in bulk rather than shifted one sample at a
    /// time, so the estimate has to survive the moment the buffer folds back on
    /// itself — which only happens after far more samples than a short test
    /// feeds it.
    func testStaysCorrectAcrossManyHistoryCompactions() {
        let tracker = track(Signal.sine(frequency: 150, frames: 240_000), blockSize: 128)

        XCTAssertTrue(tracker.isVoiced)
        XCTAssertEqual(Signal.sampleRate / tracker.periodSamples, 150, accuracy: 4)
    }

    /// The host picks the block size, and it is not always a round number.
    func testUnevenBlockSizesDoNotDisturbTheEstimate() {
        let tracker = PitchTracker(sampleRate: Signal.sampleRate, minimumHz: 60)
        let samples = Signal.sine(frequency: 180, frames: 96000)

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            var size = 37
            while offset + size <= buffer.count {
                tracker.push(base + offset, frameCount: size)
                tracker.analyse()
                offset += size
                size = size == 37 ? 511 : 37
            }
        }

        XCTAssertTrue(tracker.isVoiced)
        XCTAssertEqual(Signal.sampleRate / tracker.periodSamples, 180, accuracy: 5)
    }

    /// Resetting has to put the buffering back to its starting state, not leave
    /// a half-full history that reports a period from the previous stream.
    func testResetClearsTheEstimate() {
        let tracker = track(Signal.sine(frequency: 200, frames: 24000))
        XCTAssertTrue(tracker.isVoiced)

        tracker.reset()
        XCTAssertFalse(tracker.isVoiced)

        var silence = Signal.silence(frames: 4096)
        silence.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            tracker.push(base, frameCount: buffer.count)
            tracker.analyse()
        }
        XCTAssertFalse(tracker.isVoiced)
    }
}
