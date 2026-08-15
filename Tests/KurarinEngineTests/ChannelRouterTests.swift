import XCTest
import CoreAudio
@testable import KurarinEngine

final class ChannelRouterReadTests: XCTestCase {
    func testReadsARangeOutOfOneInterleavedBuffer() {
        let fixture = BufferListFixture(channelsPerBuffer: [6], frames: 8)
        fixture.fill(channel: 0, with: 1)   // not ours
        fixture.fill(channel: 2, with: 0.5)
        fixture.fill(channel: 3, with: 0.5)
        fixture.fill(channel: 4, with: 1)   // not ours

        let destination = MonoBuffer(frames: 8)
        ChannelRouter.readMono(
            from: fixture.list,
            channelOffset: 2,
            channelCount: 2,
            into: destination.pointer,
            frames: 8
        )

        XCTAssertEqual(destination.values, [Float](repeating: 0.5, count: 8))
    }

    /// The layout puts a device's channels wherever the sub-device order lands
    /// them, so a range can straddle two buffers.
    func testReadsARangeThatSpansTwoBuffers() {
        let fixture = BufferListFixture(channelsPerBuffer: [2, 2, 2], frames: 4)
        fixture.fill(channel: 1, with: 1)
        fixture.fill(channel: 2, with: 3)

        let destination = MonoBuffer(frames: 4)
        ChannelRouter.readMono(
            from: fixture.list,
            channelOffset: 1,
            channelCount: 2,
            into: destination.pointer,
            frames: 4
        )

        XCTAssertEqual(destination.values, [Float](repeating: 2, count: 4))
    }

    /// Stereo is averaged, not summed: the same voice must not be 6 dB louder
    /// on a stereo interface than on a mono one.
    func testStereoIsAveragedRatherThanSummed() {
        let fixture = BufferListFixture(channelsPerBuffer: [2], frames: 4)
        fixture.fill(channel: 0, with: 1)
        fixture.fill(channel: 1, with: 1)

        let destination = MonoBuffer(frames: 4)
        ChannelRouter.readMono(
            from: fixture.list,
            channelOffset: 0,
            channelCount: 2,
            into: destination.pointer,
            frames: 4
        )

        XCTAssertEqual(destination.values, [Float](repeating: 1, count: 4))
    }

    func testMonoIsLeftAtItsOriginalLevel() {
        let fixture = BufferListFixture(channelsPerBuffer: [1], frames: 4)
        fixture.fill(channel: 0, with: 0.75)

        let destination = MonoBuffer(frames: 4)
        ChannelRouter.readMono(
            from: fixture.list,
            channelOffset: 0,
            channelCount: 1,
            into: destination.pointer,
            frames: 4
        )

        XCTAssertEqual(destination.values, [Float](repeating: 0.75, count: 4))
    }

    /// One buffer per channel is a shape Core Audio really uses.
    func testReadsFromOneBufferPerChannel() {
        let fixture = BufferListFixture(channelsPerBuffer: [1, 1, 1, 1], frames: 4)
        fixture.fill(channel: 2, with: 2)
        fixture.fill(channel: 3, with: 4)

        let destination = MonoBuffer(frames: 4)
        ChannelRouter.readMono(
            from: fixture.list,
            channelOffset: 2,
            channelCount: 2,
            into: destination.pointer,
            frames: 4
        )

        XCTAssertEqual(destination.values, [Float](repeating: 3, count: 4))
    }

    func testZeroChannelsReadsNothing() {
        let fixture = BufferListFixture(channelsPerBuffer: [2], frames: 4)
        fixture.fill(channel: 0, with: 1)

        let destination = MonoBuffer(frames: 4)
        ChannelRouter.readMono(
            from: fixture.list,
            channelOffset: 0,
            channelCount: 0,
            into: destination.pointer,
            frames: 4
        )

        XCTAssertEqual(destination.values, [Float](repeating: 0, count: 4))
    }

    /// A buffer shorter than the block must not be read past its end. The tail
    /// of the destination keeps whatever the caller put there, which is why the
    /// engine clears its buffers every block.
    func testStopsAtTheEndOfAShortBuffer() {
        let fixture = BufferListFixture(channelsPerBuffer: [2], frames: 8, framesInBuffer: [4])
        fixture.fill(channel: 0, with: 1)
        fixture.fill(channel: 1, with: 1)

        let destination = MonoBuffer(frames: 8)
        ChannelRouter.readMono(
            from: fixture.list,
            channelOffset: 0,
            channelCount: 2,
            into: destination.pointer,
            frames: 8
        )

        XCTAssertEqual(Array(destination.values[0..<4]), [Float](repeating: 1, count: 4))
        XCTAssertEqual(Array(destination.values[4..<8]), [Float](repeating: 0, count: 4))
    }
}

final class ChannelRouterWriteTests: XCTestCase {
    func testWritesOnlyTheRequestedChannels() {
        let fixture = BufferListFixture(channelsPerBuffer: [6], frames: 4)
        let source = MonoBuffer(frames: 4, filledWith: 0.25)

        ChannelRouter.write(
            source.pointer,
            into: fixture.list,
            channelOffset: 2,
            channelCount: 2,
            frames: 4,
            gain: 1
        )

        XCTAssertEqual(fixture.channelValues(frame: 0), [0, 0, 0.25, 0.25, 0, 0])
    }

    func testAppliesGain() {
        let fixture = BufferListFixture(channelsPerBuffer: [2], frames: 4)
        let source = MonoBuffer(frames: 4, filledWith: 1)

        ChannelRouter.write(
            source.pointer,
            into: fixture.list,
            channelOffset: 0,
            channelCount: 2,
            frames: 4,
            gain: 0.5
        )

        XCTAssertEqual(fixture.channelValues(frame: 3), [0.5, 0.5])
    }

    /// Writing the virtual device must not disturb the monitoring channels that
    /// share the same list — the two destinations get different mixes.
    func testTwoWritesToDifferentRangesDoNotOverlap() {
        let fixture = BufferListFixture(channelsPerBuffer: [2, 2], frames: 4)
        let voice = MonoBuffer(frames: 4, filledWith: 1)
        let monitor = MonoBuffer(frames: 4, filledWith: -1)

        ChannelRouter.write(
            voice.pointer, into: fixture.list,
            channelOffset: 0, channelCount: 2, frames: 4, gain: 1
        )
        ChannelRouter.write(
            monitor.pointer, into: fixture.list,
            channelOffset: 2, channelCount: 2, frames: 4, gain: 1
        )

        XCTAssertEqual(fixture.channelValues(frame: 0), [1, 1, -1, -1])
    }

    func testWriteStopsAtTheEndOfAShortBuffer() {
        let fixture = BufferListFixture(channelsPerBuffer: [1], frames: 8, framesInBuffer: [4])
        let source = MonoBuffer(frames: 8, filledWith: 1)

        ChannelRouter.write(
            source.pointer, into: fixture.list,
            channelOffset: 0, channelCount: 1, frames: 8, gain: 1
        )

        XCTAssertEqual(fixture.value(channel: 0, frame: 3), 1)
    }

    func testSilenceClearsEveryBuffer() {
        let fixture = BufferListFixture(channelsPerBuffer: [2, 3], frames: 4)
        for channel in 0..<5 { fixture.fill(channel: channel, with: 1) }

        ChannelRouter.silence(fixture.list)

        XCTAssertEqual(fixture.channelValues(frame: 0), [0, 0, 0, 0, 0])
        XCTAssertEqual(fixture.channelValues(frame: 3), [0, 0, 0, 0, 0])
    }
}
