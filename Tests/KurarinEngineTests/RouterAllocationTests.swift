import KurarinAllocProbe
import XCTest
@testable import KurarinEngine

/// The router is the first and last thing the render callback touches, so it
/// lives under the same no-allocation rule as everything between.
///
/// `forEachOverlap` iterates an `UnsafeMutableAudioBufferListPointer` and hands
/// a closure to each call — both are shapes that allocate easily if the
/// compiler cannot see through them, which is exactly why this is worth
/// checking rather than assuming.
final class RouterAllocationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if DEBUG
        throw XCTSkip("Needs the optimiser; run: swift test -c release")
        #endif
        XCTAssertEqual(kurarin_alloc_probe_is_working(), 1, "the probe sees nothing")
    }

    /// The count has to land in a local before anything asserts on it: XCTest's
    /// arguments are autoclosures, and the assertion machinery would allocate
    /// while the probe was still counting.
    private func allocations(during body: () -> Void) -> UInt64 {
        body()
        kurarin_alloc_probe_begin()
        body()
        return kurarin_alloc_probe_end()
    }

    /// The three packings Core Audio is free to choose between, since the
    /// router walks them differently.
    private let shapes: [[Int]] = [[8], [2, 2, 2, 2], [1, 1, 1, 1, 1, 1, 1, 1]]

    func testReadingMonoAllocatesNothing() {
        for shape in shapes {
            let fixture = BufferListFixture(channelsPerBuffer: shape, frames: 512)
            var destination = [Float](repeating: 0, count: 512)
            let seen = destination.withUnsafeMutableBufferPointer { pointer -> UInt64 in
                guard let base = pointer.baseAddress else { return 0 }
                return allocations {
                    ChannelRouter.readMono(
                        from: fixture.list,
                        channelOffset: 2,
                        channelCount: 2,
                        into: base,
                        frames: 512
                    )
                }
            }
            XCTAssertEqual(seen, 0, "readMono over \(shape)")
        }
    }

    func testWritingAllocatesNothing() {
        for shape in shapes {
            let fixture = BufferListFixture(channelsPerBuffer: shape, frames: 512)
            let source = [Float](repeating: 0.25, count: 512)
            let seen = source.withUnsafeBufferPointer { pointer -> UInt64 in
                guard let base = pointer.baseAddress else { return 0 }
                return allocations {
                    ChannelRouter.write(
                        base,
                        into: fixture.list,
                        channelOffset: 1,
                        channelCount: 4,
                        frames: 512,
                        gain: 0.8
                    )
                }
            }
            XCTAssertEqual(seen, 0, "write over \(shape)")
        }
    }

    func testSilencingAllocatesNothing() {
        for shape in shapes {
            let fixture = BufferListFixture(channelsPerBuffer: shape, frames: 512)
            let seen = allocations { ChannelRouter.silence(fixture.list) }
            XCTAssertEqual(seen, 0, "silence over \(shape)")
        }
    }
}
