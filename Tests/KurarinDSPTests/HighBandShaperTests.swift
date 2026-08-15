import XCTest
@testable import KurarinDSP

final class HighBandShaperTests: XCTestCase {
    private func shaper(mix: Float, formant: Float = 1, delay: Int = 1920) -> HighBandShaper {
        let unit = HighBandShaper(sampleRate: Signal.sampleRate, delayFrames: delay)
        unit.mix = mix
        unit.formantRatio = formant
        return unit
    }

    /// What the chain hands it: everything above the split.
    private func airBand(frames: Int, amplitude: Float = 0.3, seed: UInt64 = 7) -> [Float] {
        let highPass = Biquad(sampleRate: Signal.sampleRate)
        highPass.configure(kind: .highpass, frequency: HighBandShaper.splitHz, q: 0.707)
        return highPass.process(Signal.noise(frames: frames, amplitude: amplitude, seed: seed))
    }

    /// Rough spectral centre of gravity, from the balance either side of a
    /// crossover — enough to tell whether the energy moved up.
    private func balance(_ samples: [Float], above: Float) -> Float {
        let highPass = Biquad(sampleRate: Signal.sampleRate)
        highPass.configure(kind: .highpass, frequency: above, q: 0.707)
        let top = Signal.rms(highPass.process(samples))
        let whole = Signal.rms(samples)
        return whole > 0 ? top / whole : 0
    }

    func testOffIsAPlainDelay() {
        let unit = shaper(mix: 0, delay: 256)
        let input = airBand(frames: 4800)
        let output = processStreaming(unit, input)

        for i in 256..<input.count {
            XCTAssertEqual(output[i], input[i - 256], accuracy: 1e-6)
        }
    }

    /// Rebuilt rather than repeated, but it has to come back at the level it
    /// went in at.
    func testRebuiltBandKeepsTheLevel() {
        let input = airBand(frames: 96000)
        let output = processStreaming(shaper(mix: 1, delay: 1920), input)

        let range = 48000..<95000
        let before = Signal.rms(Array(input[range]))
        let after = Signal.rms(Array(output[range]))
        XCTAssertEqual(after, before, accuracy: before * 0.4)
    }

    /// The point of moving the synthesis bands: a smaller speaker's fricatives
    /// sit higher, and pitch alone never does that.
    func testFormantRatioMovesTheAirUpwards() {
        let input = airBand(frames: 96000)

        let plain = processStreaming(shaper(mix: 1, formant: 1), input)
        let smaller = processStreaming(shaper(mix: 1, formant: 1.4), input)

        let range = 48000..<95000
        let plainBalance = balance(Array(plain[range]), above: 9000)
        let smallerBalance = balance(Array(smaller[range]), above: 9000)

        XCTAssertGreaterThan(
            smallerBalance, plainBalance * 1.1,
            "raising the formant ratio did not move the noise up the spectrum"
        )
    }

    /// It follows the envelope, so a fricative that stops has to stop.
    func testItStopsWhenTheInputStops() {
        var input = airBand(frames: 48000)
        input += Signal.silence(frames: 48000)

        let output = processStreaming(shaper(mix: 1, delay: 1920), input)

        let afterwards = Array(output[60000...])
        XCTAssertLessThan(
            Signal.rms(afterwards), Signal.rms(Array(output[24000..<47000])) * 0.05,
            "noise kept being generated after the input stopped"
        )
    }

    func testSilenceInSilenceOut() {
        let output = processStreaming(shaper(mix: 1), Signal.silence(frames: 9600))
        XCTAssertEqual(Signal.peak(output), 0)
    }

    func testStaysFiniteAndBounded() {
        let output = processStreaming(shaper(mix: 1, formant: 2), airBand(frames: 48000, amplitude: 0.9))
        XCTAssertTrue(Signal.isFinite(output))
        XCTAssertLessThan(Signal.peak(output), 4)
    }
}
