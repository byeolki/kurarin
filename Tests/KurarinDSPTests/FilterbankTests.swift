import XCTest
@testable import KurarinDSP

final class FilterbankTests: XCTestCase {
    private func bank(_ edges: [Float], floor: Float = 0) -> Filterbank {
        Filterbank(sampleRate: Signal.sampleRate, edges: edges, floor: floor)
    }

    private func run(_ bank: Filterbank, _ input: [Float], blockSize: Int = 256,
                     gain: @escaping (Int, Float, Int) -> Float) -> [Float] {
        var samples = input
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let frames = min(blockSize, buffer.count - offset)
                bank.process(base + offset, frameCount: frames, gain: gain)
                offset += frames
            }
        }
        return samples
    }

    /// The reconstruction side: with nothing changed, the bands add back to
    /// exactly the input. This is why the audio path is built from differences
    /// of lowpasses rather than from bandpasses, which dig a hole at every
    /// crossover instead.
    func testUntouchedBandsReconstructTheInputExactly() {
        let input = Signal.noise(frames: 24000, amplitude: 0.5)
        let output = run(bank([200, 800, 3000, 9000]), input) { _, _, _ in 1 }

        for i in input.indices {
            XCTAssertEqual(output[i], input[i], accuracy: 1e-5)
        }
    }

    func testLevelIsPreservedAtEveryCrossover() {
        for frequency in [80, 200, 800, 3000, 9000, 14000] as [Float] {
            let input = Signal.sine(frequency: frequency, frames: 24000)
            let output = run(bank([200, 800, 3000, 9000]), input) { _, _, _ in 1 }

            let before = Signal.rms(Array(input[12000...]))
            let after = Signal.rms(Array(output[12000...]))
            XCTAssertEqual(after, before, accuracy: before * 0.02,
                           "\(Int(frequency)) Hz came back at a different level")
        }
    }

    /// The measurement side: a tone belongs to one band and is nearly absent
    /// from the others. The failure this pins down is a measurement that
    /// reported the top band as louder than the input, because a difference of
    /// lowpasses carries the phase residue of everything below it.
    func testMeasurementPutsAToneInOneBand() {
        let bank = bank([500, 2000])
        var levels = [Float](repeating: 0, count: 3)
        let input = Signal.sine(frequency: 1000, frames: 24000)

        input.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let frames = min(256, buffer.count - offset)
                bank.measure(base + offset, frameCount: frames) { index, level, _ in
                    levels[index] = level
                }
                offset += frames
            }
        }

        XCTAssertGreaterThan(levels[1], levels[0] * 3, "the tone did not land in its own band")
        XCTAssertGreaterThan(levels[1], levels[2] * 3)
        XCTAssertLessThan(levels[0], Signal.rms(input) * 0.3)
        XCTAssertLessThan(levels[2], Signal.rms(input) * 0.3)
    }

    /// One band scaled differently from its neighbours does not carve that
    /// range out — it can even come back louder, because the phase residue the
    /// neighbouring bands used to cancel between them no longer does.
    ///
    /// Pinned down rather than fixed: the callers here pull a whole noise floor
    /// down across neighbouring bands, which the sum handles exactly, and they
    /// smooth their gains across the bank so this case does not arise. What
    /// matters is that it stays bounded rather than running away.
    func testAnIsolatedBandChangeStaysBounded() {
        let input = Signal.sine(frequency: 1000, frames: 24000)
        let output = run(bank([500, 2000]), input) { index, _, _ in index == 1 ? 0 : 1 }

        let before = Signal.rms(Array(input[12000...]))
        let after = Signal.rms(Array(output[12000...]))
        XCTAssertLessThan(after, before * 1.6)
    }

    /// The case the noise reducer actually produces: every band down together,
    /// which the telescoping sum handles exactly.
    func testTurningEveryBandDownScalesTheWholeSignal() {
        let input = Signal.noise(frames: 24000, amplitude: 0.5)
        let output = run(bank([200, 800, 3000, 9000]), input) { _, _, _ in 0.25 }

        for i in stride(from: 1000, to: 24000, by: 37) {
            XCTAssertEqual(output[i], input[i] * 0.25, accuracy: 1e-5)
        }
    }

    /// The floor is what gives the lowest band a bottom. Without it, content
    /// well below the bank's range is measured as if it belonged to band zero.
    func testFloorKeepsLowContentOutOfTheLowestBand() {
        let input = Signal.sine(frequency: 300, frames: 24000, amplitude: 0.5)

        func lowestBandLevel(_ bank: Filterbank) -> Float {
            var level: Float = 0
            input.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let frames = min(256, buffer.count - offset)
                    bank.measure(base + offset, frameCount: frames) { index, value, _ in
                        if index == 0 { level = value }
                    }
                    offset += frames
                }
            }
            return level
        }

        XCTAssertGreaterThan(lowestBandLevel(bank([7000])), 0.1)
        XCTAssertLessThan(lowestBandLevel(bank([7000], floor: 5000)), 0.02)
    }

    func testBlockSizeDoesNotChangeTheResult() {
        let input = Signal.noise(frames: 12000, amplitude: 0.4)
        let coarse = run(bank([300, 1200, 5000]), input, blockSize: 512) { index, _, _ in
            index == 0 ? 0.5 : 1
        }
        let fine = run(bank([300, 1200, 5000]), input, blockSize: 37) { index, _, _ in
            index == 0 ? 0.5 : 1
        }

        for i in stride(from: 1000, to: 12000, by: 91) {
            XCTAssertEqual(coarse[i], fine[i], accuracy: 1e-4)
        }
    }

    func testBandCountIsOneMoreThanTheEdges() {
        XCTAssertEqual(bank([100, 200, 300]).bandCount, 4)
    }
}
