import XCTest
@testable import KurarinDSP

final class PitchTrackerTests: XCTestCase {
    private func track(_ signal: [Float], minimumHz: Float = 60) -> PitchTracker {
        let tracker = PitchTracker(sampleRate: Signal.sampleRate, minimumHz: minimumHz)
        signal.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let frames = min(256, buffer.count - offset)
                tracker.push(base + offset, frameCount: frames)
                tracker.analyse()
                offset += frames
            }
        }
        return tracker
    }

    func testFindsFundamentalOfSteadyTone() {
        let tracker = track(Signal.sine(frequency: 200, frames: 24000))
        XCTAssertTrue(tracker.isVoiced)

        let detectedHz = Signal.sampleRate / tracker.periodSamples
        XCTAssertEqual(detectedHz, 200, accuracy: 4)
    }

    func testFindsLowMaleFundamental() {
        let tracker = track(Signal.sine(frequency: 85, frames: 24000))
        XCTAssertTrue(tracker.isVoiced)
        XCTAssertEqual(Signal.sampleRate / tracker.periodSamples, 85, accuracy: 3)
    }

    func testFindsHighFundamental() {
        let tracker = track(Signal.sine(frequency: 330, frames: 24000))
        XCTAssertTrue(tracker.isVoiced)
        XCTAssertEqual(Signal.sampleRate / tracker.periodSamples, 330, accuracy: 8)
    }

    func testReportsNoiseAsUnvoiced() {
        let tracker = track(Signal.noise(frames: 24000))
        XCTAssertFalse(tracker.isVoiced)
    }

    func testReportsSilenceAsUnvoiced() {
        let tracker = track(Signal.silence(frames: 24000))
        XCTAssertFalse(tracker.isVoiced)
    }

    /// The estimate is made on a quarter-rate copy and multiplied back up, so
    /// a whole-sample error in the analysis is four samples in the answer. The
    /// parabola through the minimum is what recovers the fraction, and it is
    /// worth about forty times: across this range the worst error is 0.08 Hz
    /// with it and 3.33 Hz without.
    ///
    /// The other tests here allow 3 to 8 Hz, which is the accuracy needed to
    /// name a note. This one is tight on purpose — the pitch target divides by
    /// this number, so a percent of error here is a percent of error in the
    /// voice that comes out.
    func testResolvesPitchToWellUnderAHertz() {
        var worst: Float = 0
        var worstAt: Float = 0

        for hz in [Float(85), 97, 110, 123, 140, 155, 175, 196, 220, 247, 277, 311, 330] {
            let tracker = track(Signal.sine(frequency: hz, frames: 24000))
            XCTAssertTrue(tracker.isVoiced, "\(hz) Hz was not heard as voiced")

            let error = abs(Signal.sampleRate / tracker.periodSamples - hz)
            if error > worst {
                worst = error
                worstAt = hz
            }
        }

        XCTAssertLessThan(
            worst, 0.3,
            "worst error \(worst) Hz at \(worstAt) Hz — sub-sample resolution has been lost"
        )
    }
}

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
