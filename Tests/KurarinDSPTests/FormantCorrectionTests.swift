import XCTest
@testable import KurarinDSP

final class FormantCorrectionTests: XCTestCase {
    private func energy(_ samples: [Float], around frequency: Float) -> Float {
        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .peaking, frequency: frequency, q: 2, gainDB: 0)
        // A peaking filter at unity does nothing, so measure with a bandpass
        // built from a pair of shelves instead: level above minus level below.
        let low = Biquad(sampleRate: Signal.sampleRate)
        low.configure(kind: .lowpass, frequency: frequency * 1.3, q: 0.707)
        let high = Biquad(sampleRate: Signal.sampleRate)
        high.configure(kind: .highpass, frequency: frequency / 1.3, q: 0.707)
        return Signal.rms(high.process(low.process(samples)))
    }

    func testUnityRatioChangesNothing() {
        let corrector = FormantCorrector(sampleRate: Signal.sampleRate)
        corrector.ratio = 1
        let input = Signal.noise(frames: 24000, amplitude: 0.5)
        XCTAssertEqual(processStreaming(corrector, input), input)
    }

    /// Raising formants uniformly lifts the first formant too far; the
    /// correction pulls the bottom back.
    func testRaisedFormantsGetTheirLowEndPulledBack() {
        let corrector = FormantCorrector(sampleRate: Signal.sampleRate)
        corrector.ratio = 1.3

        let input = Signal.noise(frames: 48000, amplitude: 0.5)
        let output = processStreaming(corrector, input)

        let lowBefore = energy(input, around: 400)
        let lowAfter = energy(output, around: 400)
        let highBefore = energy(input, around: 5000)
        let highAfter = energy(output, around: 5000)

        XCTAssertLessThan(lowAfter, lowBefore * 0.95, "the low end was not pulled back")
        XCTAssertGreaterThan(highAfter, highBefore * 1.05, "the top was not lifted")
    }

    /// Lowering formants is the same problem mirrored.
    func testLoweredFormantsGetTheOppositeTilt() {
        let corrector = FormantCorrector(sampleRate: Signal.sampleRate)
        corrector.ratio = 0.8

        let input = Signal.noise(frames: 48000, amplitude: 0.5)
        let output = processStreaming(corrector, input)

        XCTAssertGreaterThan(energy(output, around: 400), energy(input, around: 400) * 1.05)
        XCTAssertLessThan(energy(output, around: 5000), energy(input, around: 5000) * 0.95)
    }

    func testAmountZeroDisablesIt() {
        let corrector = FormantCorrector(sampleRate: Signal.sampleRate)
        corrector.ratio = 1.5
        corrector.amount = 0
        let input = Signal.noise(frames: 24000, amplitude: 0.5)
        XCTAssertEqual(processStreaming(corrector, input), input)
    }

    func testStaysFinite() {
        let corrector = FormantCorrector(sampleRate: Signal.sampleRate)
        corrector.ratio = 2
        XCTAssertTrue(Signal.isFinite(processStreaming(corrector, Signal.noise(frames: 24000, amplitude: 0.9))))
    }
}
