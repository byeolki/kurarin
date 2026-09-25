import XCTest
@testable import KurarinEngine

/// Where the tap's channels sit, and what happens when the arithmetic and the
/// device disagree.
///
/// Getting this wrong does not cost the shared sound — it costs the voice. The
/// offsets run in sequence, so a tap that is not the width or the position it
/// was assumed to be moves every channel after it, and the microphone ends up
/// read from somewhere else entirely.
final class TapLayoutTests: XCTestCase {
    private func device(_ uid: String, inputs: Int, outputs: Int) -> AudioDeviceInfo {
        AudioDeviceInfo(id: 0, uid: uid, name: uid, inputChannels: inputs, outputChannels: outputs, transportType: 0)
    }

    func testTheTapSitsAfterEveryDeviceInput() {
        let microphone = device("mic", inputs: 2, outputs: 0)
        let virtual = device("virtual", inputs: 2, outputs: 2)
        let monitor = device("monitor", inputs: 0, outputs: 2)

        let layout = AggregateDevice.computeLayout(
            subDevices: [microphone, virtual, monitor],
            microphone: microphone,
            virtualDevice: virtual,
            monitor: monitor,
            tapChannels: 2
        )

        XCTAssertEqual(layout.microphoneInputOffset, 0)
        XCTAssertEqual(layout.microphoneChannels, 2)
        // Two from the microphone, two from the virtual device's own inputs.
        XCTAssertEqual(layout.tapInputOffset, 4)
        XCTAssertEqual(layout.tapChannels, 2)
    }

    /// A tap of a different width moves nothing before it and everything after.
    func testTheTapWidthDoesNotMoveTheMicrophone() {
        let microphone = device("mic", inputs: 1, outputs: 0)
        let virtual = device("virtual", inputs: 2, outputs: 2)

        for width in [0, 1, 2, 8] {
            let layout = AggregateDevice.computeLayout(
                subDevices: [microphone, virtual],
                microphone: microphone,
                virtualDevice: virtual,
                monitor: nil,
                tapChannels: width
            )
            XCTAssertEqual(layout.microphoneInputOffset, 0, "width \(width)")
            XCTAssertEqual(layout.microphoneChannels, 1, "width \(width)")
            XCTAssertEqual(layout.tapInputOffset, 3, "width \(width)")
            XCTAssertEqual(layout.tapChannels, width, "width \(width)")
        }
    }

    /// Dropping the tap has to leave the rest of the layout exactly as it was,
    /// because that is the recovery path when the device disagrees with the
    /// arithmetic: the voice keeps working and only the shared sound is lost.
    func testDroppingTheTapLeavesEverythingElseWhereItWas() {
        let microphone = device("mic", inputs: 2, outputs: 0)
        let virtual = device("virtual", inputs: 2, outputs: 2)
        let monitor = device("monitor", inputs: 0, outputs: 2)
        let devices = [microphone, virtual, monitor]

        let withTap = AggregateDevice.computeLayout(
            subDevices: devices, microphone: microphone,
            virtualDevice: virtual, monitor: monitor, tapChannels: 2
        )
        let without = AggregateDevice.computeLayout(
            subDevices: devices, microphone: microphone,
            virtualDevice: virtual, monitor: monitor, tapChannels: 0
        )

        XCTAssertEqual(withTap.microphoneInputOffset, without.microphoneInputOffset)
        XCTAssertEqual(withTap.microphoneChannels, without.microphoneChannels)
        XCTAssertEqual(withTap.virtualOutputOffset, without.virtualOutputOffset)
        XCTAssertEqual(withTap.monitorOutputOffset, without.monitorOutputOffset)
        XCTAssertEqual(without.tapChannels, 0)
    }
}
