import KurarinAllocProbe
import XCTest
@testable import KurarinSoundboard

/// The mixer renders from the audio callback, so it lives under the same rule
/// as the DSP units: no heap traffic, in either direction.
///
/// Freeing matters here as much as allocating. A sample replaced while it is
/// playing leaves the old buffer with nothing pointing at it, and releasing
/// that on the audio thread takes the same lock a malloc would — which is why
/// `collectRetiredBuffers` exists and why the callback must not be the thing
/// that drops the last reference.
final class MixerAllocationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if DEBUG
        throw XCTSkip("Needs the optimiser; run: swift test -c release")
        #endif
        XCTAssertEqual(kurarin_alloc_probe_is_working(), 1, "the probe sees nothing")
    }

    /// Takes the count before anything else runs.
    ///
    /// `XCTAssertEqual(kurarin_alloc_probe_end(), 0)` does not work: the
    /// arguments are autoclosures, so the assertion machinery gets to allocate
    /// while the probe is still counting and every measurement comes back one
    /// or two high. The count has to land in a plain local first.
    private func render(_ mixer: SoundboardMixer, blocks: Int = 100) -> UInt64 {
        var buffer = [Float](repeating: 0, count: 256)
        func sweep() {
            buffer.withUnsafeMutableBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                for _ in 0..<blocks { mixer.render(into: base, frameCount: 256) }
            }
        }
        sweep()
        kurarin_alloc_probe_begin()
        sweep()
        return kurarin_alloc_probe_end()
    }

    func testRenderingSilenceAllocatesNothing() {
        XCTAssertEqual(render(SoundboardMixer()), 0)
    }

    func testRenderingActiveVoicesAllocatesNothing() {
        let mixer = SoundboardMixer()
        let sample = (0..<12000).map { sinf(Float($0) * 0.05) * 0.5 }
        for slot in 0..<4 {
            XCTAssertTrue(mixer.install(sample, at: slot))
            mixer.play(slot: slot, gain: 0.8, loops: slot % 2 == 0)
        }
        XCTAssertEqual(render(mixer), 0)
    }

    /// A voice running off the end of its sample retires it. That retirement
    /// must not be where the buffer is freed.
    func testVoicesEndingMidBlockAllocateNothing() {
        let mixer = SoundboardMixer()
        let sample = (0..<600).map { sinf(Float($0) * 0.05) * 0.5 }
        for slot in 0..<4 {
            XCTAssertTrue(mixer.install(sample, at: slot))
        }
        // Started before the measurement: play is a control-thread call and
        // is allowed to allocate. What must not is the render that watches
        // these voices run off the end of their sample and retire.
        for slot in 0..<4 { mixer.play(slot: slot) }

        var buffer = [Float](repeating: 0, count: 256)
        var seen: UInt64 = 0
        buffer.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            kurarin_alloc_probe_begin()
            // 20 blocks of 256 is well past the 600-sample samples, so every
            // voice retires inside the measured region.
            for _ in 0..<20 { mixer.render(into: base, frameCount: 256) }
            seen = kurarin_alloc_probe_end()
        }
        XCTAssertEqual(seen, 0)
    }
}
