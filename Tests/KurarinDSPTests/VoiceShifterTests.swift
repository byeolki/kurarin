import XCTest
@testable import KurarinDSP

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
}

final class VoiceShifterTests: XCTestCase {
    /// A vowel-like source: a fundamental with a few harmonics, which is what
    /// the pitch tracker and the overlap-add actually have to cope with.
    private func voiceLike(frequency: Float, frames: Int) -> [Float] {
        var signal = [Float](repeating: 0, count: frames)
        for (index, harmonic) in [1, 2, 3, 4, 5].enumerated() {
            let amplitude = 0.4 / Float(index + 1)
            let partial = Signal.sine(
                frequency: frequency * Float(harmonic),
                frames: frames,
                amplitude: amplitude
            )
            for i in 0..<frames { signal[i] += partial[i] }
        }
        return signal
    }

    func testRaisesPitchByRequestedRatio() {
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .quality)
        shifter.pitchRatio = 2
        shifter.formantRatio = 1

        let input = voiceLike(frequency: 150, frames: 48000)
        let output = processStreaming(shifter, input)

        // Skip the latency ramp and the tracker's warm-up.
        let settled = Array(output[24000...])
        let detected = Signal.dominantFrequency(settled)
        XCTAssertNotNil(detected)
        XCTAssertEqual(detected!, 300, accuracy: 12)
    }

    func testLowersPitchByRequestedRatio() {
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .quality)
        shifter.pitchRatio = 0.5

        let input = voiceLike(frequency: 200, frames: 48000)
        let output = processStreaming(shifter, input)

        let detected = Signal.dominantFrequency(Array(output[24000...]))
        XCTAssertNotNil(detected)
        XCTAssertEqual(detected!, 100, accuracy: 6)
    }

    func testFormantShiftLeavesFundamentalAlone() {
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .quality)
        shifter.pitchRatio = 1
        shifter.formantRatio = 1.6

        let input = voiceLike(frequency: 180, frames: 48000)
        let output = processStreaming(shifter, input)

        // This is the property the whole design rests on: the two controls are
        // independent, so a formant move must not drag the pitch with it.
        let detected = Signal.dominantFrequency(Array(output[24000...]))
        XCTAssertNotNil(detected)
        XCTAssertEqual(detected!, 180, accuracy: 8)
    }

    func testUnityRatiosPassSignalThrough() {
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        let input = voiceLike(frequency: 200, frames: 24000)
        let output = processStreaming(shifter, input)

        // Bypassed, but still delayed by the fixed latency so that toggling an
        // effect does not jump the stream.
        let delay = shifter.latencyFrames
        let expected = Array(input[(12000 - delay)..<(20000 - delay)])
        let actual = Array(output[12000..<20000])
        for (a, b) in zip(expected, actual) {
            XCTAssertEqual(a, b, accuracy: 1e-5)
        }
    }

    func testStaysFiniteAndBoundedOnNoise() {
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        shifter.pitchRatio = 1.8
        shifter.formantRatio = 1.4

        let output = processStreaming(shifter, Signal.noise(frames: 48000, amplitude: 0.8))
        XCTAssertTrue(Signal.isFinite(output))
        XCTAssertLessThan(Signal.peak(output), 4)
    }

    func testPreservesLevelAcrossPitchRatios() {
        let input = voiceLike(frequency: 180, frames: 48000)
        let reference = Signal.rms(Array(input[24000...]))

        for ratio in [Float(0.6), 0.8, 1.25, 1.7] {
            let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
            shifter.pitchRatio = ratio
            let output = processStreaming(shifter, input)
            let level = Signal.rms(Array(output[24000...]))
            // Overlap-add normalisation should hold the level within a few dB
            // regardless of how far the pitch moved.
            XCTAssertEqual(level, reference, accuracy: reference * 0.5, "ratio \(ratio)")
        }
    }

    func testSilenceInSilenceOut() {
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        shifter.pitchRatio = 1.5
        let output = processStreaming(shifter, Signal.silence(frames: 24000))
        XCTAssertEqual(Signal.peak(output), 0)
    }

    func testLatencyMatchesModeExpectations() {
        let low = VoiceShifter(sampleRate: 48000, latencyMode: .low)
        let balanced = VoiceShifter(sampleRate: 48000, latencyMode: .balanced)
        let quality = VoiceShifter(sampleRate: 48000, latencyMode: .quality)

        XCTAssertLessThan(low.latencyFrames, balanced.latencyFrames)
        XCTAssertLessThan(balanced.latencyFrames, quality.latencyFrames)
        XCTAssertLessThan(Float(quality.latencyFrames) / 48000, 0.055)
    }
}
