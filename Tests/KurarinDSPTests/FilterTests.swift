import XCTest
@testable import KurarinDSP

final class BiquadTests: XCTestCase {
    func testHighpassAttenuatesBelowCorner() {
        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .highpass, frequency: 500, q: 0.707)

        let input = Signal.sine(frequency: 60, frames: 4800)
        let output = filter.process(input)

        // Ignore the transient at the start of the response.
        let settled = output[2400...]
        XCTAssertLessThan(Signal.rms(settled), Signal.rms(input) * 0.1)
    }

    func testHighpassPassesAboveCorner() {
        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .highpass, frequency: 100, q: 0.707)

        let input = Signal.sine(frequency: 2000, frames: 4800)
        let output = filter.process(input)

        let settled = output[2400...]
        XCTAssertEqual(Signal.rms(settled), Signal.rms(input), accuracy: Signal.rms(input) * 0.05)
    }

    func testStaysFiniteOnNoise() {
        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .peaking, frequency: 1000, q: 8, gainDB: 18)
        XCTAssertTrue(Signal.isFinite(filter.process(Signal.noise(frames: 9600))))
    }

    func testSilenceInSilenceOut() {
        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .lowShelf, frequency: 200, q: 0.707, gainDB: 12)
        XCTAssertEqual(Signal.peak(filter.process(Signal.silence(frames: 1024))), 0)
    }
}

final class ParametricEQTests: XCTestCase {
    func testBoostRaisesEnergyAtBandFrequency() {
        let eq = ParametricEQ(sampleRate: Signal.sampleRate)
        eq.setBands([
            .init(frequency: 120,  q: 0.707, gainDB: 0),
            .init(frequency: 1000, q: 2.0,   gainDB: 12),
            .init(frequency: 1200, q: 1.0,   gainDB: 0),
            .init(frequency: 3500, q: 1.0,   gainDB: 0),
            .init(frequency: 8000, q: 0.707, gainDB: 0),
        ])

        let input = Signal.sine(frequency: 1000, frames: 9600)
        let output = eq.process(input)

        let settled = output[4800...]
        XCTAssertGreaterThan(Signal.rms(settled), Signal.rms(input) * 2)
    }

    func testFlatEQLeavesSignalUnchanged() {
        let eq = ParametricEQ(sampleRate: Signal.sampleRate)
        let input = Signal.sine(frequency: 440, frames: 2048)
        XCTAssertEqual(eq.process(input), input)
    }
}
