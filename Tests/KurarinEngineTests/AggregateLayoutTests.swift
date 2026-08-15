import XCTest
import CoreAudio
@testable import KurarinEngine

/// The channel map the render callback trusts.
///
/// An aggregate presents its sub-devices' channels concatenated in the order
/// they were listed, inputs and outputs counted separately, with tap channels
/// appended after the sub-devices. These tests pin that contract down: an
/// off-by-one here does not crash or fall silent, it quietly routes the wrong
/// device, which is the hardest kind of bug to spot by ear.
final class AggregateLayoutTests: XCTestCase {
    private func device(
        _ name: String,
        input: Int,
        output: Int
    ) -> AudioDeviceInfo {
        AudioDeviceInfo(
            id: AudioObjectID(name.hashValue & 0xFFFF),
            uid: "uid.\(name)",
            name: name,
            inputChannels: input,
            outputChannels: output,
            transportType: UInt32(kAudioDeviceTransportTypeUSB)
        )
    }

    func testTypicalSetup() {
        let layout = AggregateDevice.computeLayout(
            microphone: device("mic", input: 2, output: 0),
            virtualDevice: device("kurarin", input: 2, output: 2),
            monitor: device("headphones", input: 0, output: 2),
            tapChannels: 2
        )

        XCTAssertEqual(layout.microphoneInputOffset, 0)
        XCTAssertEqual(layout.microphoneChannels, 2)
        // Past the microphone's 2 and the virtual device's 2 inputs.
        XCTAssertEqual(layout.tapInputOffset, 4)
        XCTAssertEqual(layout.tapChannels, 2)

        // The microphone contributes no outputs, so the virtual device is first.
        XCTAssertEqual(layout.virtualOutputOffset, 0)
        XCTAssertEqual(layout.virtualChannels, 2)
        XCTAssertEqual(layout.monitorOutputOffset, 2)
        XCTAssertEqual(layout.monitorChannels, 2)
    }

    /// A USB headset is one device with both a microphone and speakers, so its
    /// output channels come before the virtual device's.
    func testMicrophoneWithOutputsPushesTheVirtualDeviceAlong() {
        let layout = AggregateDevice.computeLayout(
            microphone: device("headset", input: 1, output: 2),
            virtualDevice: device("kurarin", input: 2, output: 2),
            monitor: device("speakers", input: 0, output: 2),
            tapChannels: 0
        )

        XCTAssertEqual(layout.microphoneInputOffset, 0)
        XCTAssertEqual(layout.microphoneChannels, 1)
        XCTAssertEqual(layout.virtualOutputOffset, 2)
        XCTAssertEqual(layout.monitorOutputOffset, 4)
        XCTAssertEqual(layout.tapChannels, 0)
    }

    func testWithoutAMonitorTheTapStillFollowsTheSubDevices() {
        let layout = AggregateDevice.computeLayout(
            microphone: device("mic", input: 2, output: 0),
            virtualDevice: device("kurarin", input: 2, output: 2),
            monitor: nil,
            tapChannels: 2
        )

        XCTAssertEqual(layout.tapInputOffset, 4)
        XCTAssertEqual(layout.monitorChannels, 0)
        XCTAssertEqual(layout.virtualOutputOffset, 0)
    }

    /// A monitor with a microphone of its own occupies input channels too, and
    /// the tap sits after all of them.
    func testMonitorWithInputsShiftsTheTap() {
        let layout = AggregateDevice.computeLayout(
            microphone: device("mic", input: 2, output: 0),
            virtualDevice: device("kurarin", input: 2, output: 2),
            monitor: device("interface", input: 4, output: 2),
            tapChannels: 2
        )

        XCTAssertEqual(layout.tapInputOffset, 8)
        XCTAssertEqual(layout.monitorOutputOffset, 2)
    }

    /// Zero channels everywhere has to stay a no-op rather than reading channel
    /// -1: the render callback consults the layout before it knows anything
    /// about the devices behind it.
    func testEmptyLayoutIsHarmless() {
        let layout = AggregateDevice.Layout()

        XCTAssertEqual(layout.microphoneChannels, 0)
        XCTAssertEqual(layout.virtualChannels, 0)
        XCTAssertEqual(layout.monitorChannels, 0)
        XCTAssertEqual(layout.tapChannels, 0)

        let fixture = BufferListFixture(channelsPerBuffer: [2], frames: 4)
        fixture.fill(channel: 0, with: 1)
        let destination = MonoBuffer(frames: 4)

        ChannelRouter.readMono(
            from: fixture.list,
            channelOffset: layout.microphoneInputOffset,
            channelCount: layout.microphoneChannels,
            into: destination.pointer,
            frames: 4
        )

        XCTAssertEqual(destination.values, [Float](repeating: 0, count: 4))
    }
}
