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

    /// Sweeping a filter is the normal case — a user dragging a slider — and it
    /// must not ring or blow up as the coefficients move.
    func testSweepingTheCornerBetweenBlocksStaysStable() {
        let filter = Biquad(sampleRate: Signal.sampleRate)
        var input = Signal.sine(frequency: 440, frames: 9600)

        input.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var frame = 0
            var frequency: Float = 100
            while frame < buffer.count {
                filter.configure(kind: .peaking, frequency: frequency, q: 6, gainDB: 15)
                filter.process(base + frame, frameCount: 128)
                frequency += 40
                frame += 128
            }
        }

        XCTAssertTrue(Signal.isFinite(input))
        XCTAssertLessThan(Signal.peak(input), 12)
    }
}

final class ParameterSlotTests: XCTestCase {
    private struct Pair: BitwiseCopyable, Equatable {
        var first: Int
        var second: Int
    }

    /// Wide on purpose. A tear is a preemption landing inside the reader's
    /// copy, so how likely it is depends on how long that copy takes — with two
    /// words it happens perhaps once in a million reads, which is often enough
    /// to matter on an audio thread and far too rare for a test to rely on.
    /// Sixty-four words make the same flaw show up in the first few thousand.
    private struct Wide: BitwiseCopyable {
        var values: (
            Int, Int, Int, Int, Int, Int, Int, Int,
            Int, Int, Int, Int, Int, Int, Int, Int,
            Int, Int, Int, Int, Int, Int, Int, Int,
            Int, Int, Int, Int, Int, Int, Int, Int,
            Int, Int, Int, Int, Int, Int, Int, Int,
            Int, Int, Int, Int, Int, Int, Int, Int,
            Int, Int, Int, Int, Int, Int, Int, Int,
            Int, Int, Int, Int, Int, Int, Int, Int
        )

        init(_ value: Int) {
            values = (
                value, value, value, value, value, value, value, value,
                value, value, value, value, value, value, value, value,
                value, value, value, value, value, value, value, value,
                value, value, value, value, value, value, value, value,
                value, value, value, value, value, value, value, value,
                value, value, value, value, value, value, value, value,
                value, value, value, value, value, value, value, value,
                value, value, value, value, value, value, value, value
            )
        }

        var checksum: Int {
            withUnsafeBytes(of: values) { raw in
                raw.bindMemory(to: Int.self).reduce(0, &+)
            }
        }

        var isConsistent: Bool {
            withUnsafeBytes(of: values) { raw in
                let words = raw.bindMemory(to: Int.self)
                return words.allSatisfy { $0 == words[0] }
            }
        }
    }

    /// The same property under a copy wide enough to be caught mid-way.
    ///
    /// This is a race detector, and it is honest to say what that means: a tear
    /// needs a preemption to land inside the reader's copy, so the test cannot
    /// force one. Measured against a deliberately broken version — the count
    /// check removed — it fails on most runs but not all. It is worth having
    /// anyway, because a regression here is silent and this is the only thing
    /// that would notice, but a green run is weaker evidence than usual.
    func testAWideValueIsNeverObservedHalfApplied() {
        for attempt in 0..<6 {
            let slot = ParameterSlot(Wide(0))
            let publishing = expectation(description: "publisher \(attempt) finished")

            DispatchQueue.global(qos: .userInitiated).async {
                for value in 1...400_000 { slot.publish(Wide(value)) }
                publishing.fulfill()
            }

            var torn = 0
            var sink = 0
            for _ in 0..<400_000 {
                let observed = slot.load()
                if !observed.isConsistent { torn += 1 }
                // Keeps the copy from being optimised into nothing, and holds
                // the reader inside its window a little longer.
                sink &+= observed.checksum
            }

            wait(for: [publishing], timeout: 60)
            XCTAssertEqual(torn, 0, "a reader saw half of one set and half of another")
            XCTAssertNotEqual(sink, .max)
        }
    }

    func testLoadReturnsTheLastPublishedValue() {
        let slot = ParameterSlot(Pair(first: 0, second: 0))
        XCTAssertEqual(slot.load(), Pair(first: 0, second: 0))

        slot.publish(Pair(first: 7, second: 7))
        XCTAssertEqual(slot.load(), Pair(first: 7, second: 7))
    }

    /// The point of the slot: a reader never sees one field from one set and
    /// another field from the next.
    ///
    /// Run long, because this is a race. Three slots alone made tearing rare
    /// rather than impossible, and "rare" showed up here about once in two
    /// hundred thousand reads — which on an audio thread is a crack in a
    /// sentence every few minutes.
    func testConcurrentPublishesAreNeverObservedHalfApplied() {
        let slot = ParameterSlot(Pair(first: 0, second: 0))
        let publishing = expectation(description: "publisher finished")

        DispatchQueue.global().async {
            for value in 1...1_000_000 {
                slot.publish(Pair(first: value, second: value))
            }
            publishing.fulfill()
        }

        var torn = 0
        for _ in 0..<1_000_000 {
            let observed = slot.load()
            if observed.first != observed.second { torn += 1 }
        }
        XCTAssertEqual(torn, 0, "a reader saw half of one set and half of another")

        wait(for: [publishing], timeout: 30)
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
