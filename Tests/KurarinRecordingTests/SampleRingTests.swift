import KurarinAllocProbe
import XCTest
@testable import KurarinRecording

/// The ring is the only thing between the audio thread and a file write, so it
/// has to hand over every sample in order, never allocate, and be honest about
/// what it had to drop.
final class SampleRingTests: XCTestCase {
    private func write(_ ring: SampleRing, _ values: [Float]) {
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ring.write(base, count: buffer.count)
        }
    }

    private func read(_ ring: SampleRing, count: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: count)
        let taken = out.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return ring.read(into: base, count: count)
        }
        return Array(out[0..<taken])
    }

    func testHandsBackWhatWentIn() {
        let ring = SampleRing(sampleRate: 48000, seconds: 1)
        write(ring, [1, 2, 3, 4, 5])
        XCTAssertEqual(read(ring, count: 8), [1, 2, 3, 4, 5])
        XCTAssertEqual(ring.available, 0)
    }

    func testKeepsOrderAcrossTheWrapPoint() {
        // Small enough that a few blocks go round the end.
        let ring = SampleRing(sampleRate: 4000, seconds: 1)
        var expected: [Float] = []
        var got: [Float] = []
        for block in 0..<40 {
            let values = (0..<300).map { Float(block * 300 + $0) }
            write(ring, values)
            expected.append(contentsOf: values)
            got.append(contentsOf: read(ring, count: 300))
        }
        XCTAssertEqual(got, expected)
    }

    func testAnOverrunLosesWholeBlocksAndSaysSo() {
        let ring = SampleRing(sampleRate: 1000, seconds: 1)
        // Never read: everything past the first second has nowhere to go.
        for block in 0..<10 {
            write(ring, (0..<200).map { Float(block * 200 + $0) })
        }
        XCTAssertGreaterThan(ring.dropped, 0, "the ring silently swallowed an overrun")

        // Whole blocks, which is the part that needs stating: a ring that wrote
        // as much of a block as would fit would leave the count at some
        // arbitrary number, and the recorder could no longer say how long the
        // gap it is about to write actually is.
        XCTAssertEqual(
            ring.dropped % 200, 0,
            "a block was dropped in part: \(ring.dropped) is not a whole number of blocks"
        )

        // And what survived is a prefix rather than a mixture.
        let kept = read(ring, count: 10000)
        XCTAssertEqual(kept, (0..<kept.count).map { Float($0) })
    }

    func testWritingIsRealTimeSafe() {
        #if DEBUG
        // Same reason as the DSP allocation tests: without the optimiser Swift
        // allocates per loop iteration for bookkeeping release removes.
        #else
        XCTAssertEqual(kurarin_alloc_probe_is_working(), 1)
        let ring = SampleRing(sampleRate: 48000, seconds: 2)
        var block = [Float](repeating: 0.5, count: 256)
        var scratch = [Float](repeating: 0, count: 256)

        func round() {
            block.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                for _ in 0..<100 { ring.write(base, count: 256) }
            }
            scratch.withUnsafeMutableBufferPointer { sink in
                guard let base = sink.baseAddress else { return }
                for _ in 0..<100 { _ = ring.read(into: base, count: 256) }
            }
        }

        round()
        kurarin_alloc_probe_begin()
        round()
        let seen = kurarin_alloc_probe_end()
        XCTAssertEqual(seen, 0, "the ring allocates")
        #endif
    }
}
