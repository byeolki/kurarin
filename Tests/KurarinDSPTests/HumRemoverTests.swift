import XCTest
@testable import KurarinDSP

final class HumRemoverTests: XCTestCase {
    /// Mains hum: a fundamental and a run of harmonics, the odd ones stronger,
    /// which is what a transformer or a ground loop actually puts out.
    private func hum(_ fundamental: Float, frames: Int, amplitude: Float = 0.05) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        for harmonic in 1...6 {
            let level = amplitude / Float(harmonic)
            let partial = Signal.sine(
                frequency: fundamental * Float(harmonic),
                frames: frames,
                amplitude: level
            )
            for i in 0..<frames { samples[i] += partial[i] }
        }
        return samples
    }

    private func voice(frames: Int, f0: Float = 130) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        for harmonic in 1...10 {
            let partial = Signal.sine(
                frequency: f0 * Float(harmonic),
                frames: frames,
                amplitude: 0.3 / Float(harmonic)
            )
            for i in 0..<frames { samples[i] += partial[i] }
        }
        return samples
    }

    private func remover(_ strength: Float) -> HumRemover {
        let unit = HumRemover(sampleRate: Signal.sampleRate)
        unit.strength = strength
        return unit
    }

    private func levelAround(_ samples: [Float], _ frequency: Float) -> Float {
        let first = Biquad(sampleRate: Signal.sampleRate)
        first.configure(kind: .peaking, frequency: frequency, q: 8, gainDB: 24)
        return Signal.rms(first.process(samples))
    }

    func testFindsFiftyHertz() {
        let unit = remover(1)
        _ = processStreaming(unit, hum(50, frames: 48000))
        XCTAssertEqual(unit.detectedHz, 50)
    }

    func testFindsSixtyHertz() {
        let unit = remover(1)
        _ = processStreaming(unit, hum(60, frames: 48000))
        XCTAssertEqual(unit.detectedHz, 60)
    }

    /// Notching a frequency that carries no hum removes nothing and dents
    /// whatever the voice had there, so a quiet room has to leave it alone.
    func testFindsNothingInAQuietRoom() {
        let unit = remover(1)
        _ = processStreaming(unit, Signal.noise(frames: 96000, amplitude: 0.02))
        XCTAssertEqual(unit.detectedHz, 0)
    }

    func testFindsNothingInAVoiceAlone() {
        let unit = remover(1)
        _ = processStreaming(unit, voice(frames: 96000))
        XCTAssertEqual(unit.detectedHz, 0)
    }

    func testRemovesTheHum() {
        let input = hum(60, frames: 96000)
        let output = processStreaming(remover(1), input)

        let range = 48000..<95000
        let before = Signal.rms(Array(input[range]))
        let after = Signal.rms(Array(output[range]))
        XCTAssertLessThan(after, before * 0.25, "the hum survived")
    }

    /// The harmonics are the part that is heard over a voice; the fundamental
    /// is usually already gone to the high pass.
    func testRemovesTheHarmonicsAsWellAsTheFundamental() {
        let input = hum(60, frames: 96000)
        let output = processStreaming(remover(1), input)
        let range = 48000..<95000

        for harmonic in 1...4 {
            let frequency = 60 * Float(harmonic)
            let before = levelAround(Array(input[range]), frequency)
            let after = levelAround(Array(output[range]), frequency)
            XCTAssertLessThan(after, before * 0.4, "\(Int(frequency)) Hz survived")
        }
    }

    /// The whole reason for narrow notches: a voice sitting on top of the hum
    /// has to come through.
    func testAVoiceOverHumKeepsItsLevel() {
        let clean = voice(frames: 96000)
        var noisy = clean
        let interference = hum(60, frames: 96000)
        for i in noisy.indices { noisy[i] += interference[i] }

        let output = processStreaming(remover(1), noisy)
        let range = 48000..<95000

        XCTAssertGreaterThan(
            Signal.rms(Array(output[range])),
            Signal.rms(Array(clean[range])) * 0.85,
            "the voice was notched along with the hum"
        )
    }

    func testOffChangesNothing() {
        let input = hum(50, frames: 24000)
        XCTAssertEqual(processStreaming(remover(0), input), input)
    }

    func testStaysFiniteAndSilentOnSilence() {
        let unit = remover(1)
        XCTAssertEqual(Signal.peak(processStreaming(unit, Signal.silence(frames: 24000))), 0)
        XCTAssertTrue(Signal.isFinite(processStreaming(unit, Signal.noise(frames: 24000, amplitude: 0.9))))
    }
}

extension HumRemoverTests {
    /// Switching off has to discard the half-finished measurement.
    ///
    /// A window that resumes across a gap measures a second of audio that was
    /// never contiguous — nine tenths of it hum from before the pause and a
    /// tenth of it whatever is playing now — and reports whichever of those
    /// happened to dominate.
    func testTurningItOffDiscardsThePartialMeasurement() {
        let unit = remover(1)

        // Most of a window of hum, but not a whole one.
        _ = processStreaming(unit, hum(60, frames: 40000))
        XCTAssertEqual(unit.detectedHz, 0, "no window has completed yet")

        unit.strength = 0
        _ = processStreaming(unit, Signal.silence(frames: 4800))

        // Back on, in a room that now has no hum in it at all. Just enough to
        // complete one window and no more: a second one would be all noise and
        // would clear the verdict by itself, which is how this test passed
        // against the very code it was written to catch.
        unit.strength = 1
        _ = processStreaming(unit, Signal.noise(frames: 12000, amplitude: 0.02))
        XCTAssertEqual(unit.detectedHz, 0, "hum from before the pause was counted as hum now")
    }

    /// And it still finds hum that arrives after the pause.
    func testItStillFindsHumAfterBeingTurnedBackOn() {
        let unit = remover(1)
        _ = processStreaming(unit, hum(50, frames: 40000))

        unit.strength = 0
        _ = processStreaming(unit, Signal.silence(frames: 4800))
        unit.strength = 1
        _ = processStreaming(unit, hum(50, frames: 96000))

        XCTAssertEqual(unit.detectedHz, 50)
    }
}
