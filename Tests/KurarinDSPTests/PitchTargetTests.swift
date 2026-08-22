import XCTest
@testable import KurarinDSP

/// What the pitch target promises the user, and the one case where it cannot
/// keep the promise.
final class PitchTargetTests: XCTestCase {
    func testLandsOnTheTargetWhenItIsReachable() {
        XCTAssertEqual(VoiceChain.landingPitch(heard: 110, target: 200), 200, accuracy: 0.01)
        XCTAssertEqual(VoiceChain.landingPitch(heard: 200, target: 110), 110, accuracy: 0.01)
        XCTAssertEqual(VoiceChain.landingPitch(heard: 150, target: 150), 150, accuracy: 0.01)
    }

    /// The bound is an octave either way, so a deep voice aimed at the top of
    /// the range lands short. Landing short is fine; landing short without
    /// saying so is what the interface has to avoid.
    func testLandsShortWhenTheTargetIsMoreThanAnOctaveAway() {
        // 90 Hz aimed at 320 Hz wants a ratio of 3.6 and is allowed 2.
        XCTAssertEqual(VoiceChain.landingPitch(heard: 90, target: 320), 180, accuracy: 0.01)
        // And the same downwards.
        XCTAssertEqual(VoiceChain.landingPitch(heard: 300, target: 70), 150, accuracy: 0.01)
    }

    func testExactlyAnOctaveIsStillReachable() {
        XCTAssertEqual(VoiceChain.landingPitch(heard: 100, target: 200), 200, accuracy: 0.01)
        XCTAssertEqual(VoiceChain.landingPitch(heard: 200, target: 100), 100, accuracy: 0.01)
    }

    func testSurvivesNoMeasurement() {
        XCTAssertEqual(VoiceChain.ratio(from: 0, to: 200), 1, accuracy: 0.01)
        XCTAssertEqual(VoiceChain.landingPitch(heard: 0, target: 200), 0, accuracy: 0.01)
    }

    /// The bound the calculation uses has to be the bound the shifter enforces,
    /// or the interface will promise something the audio does not deliver.
    ///
    /// Asserting that the shifter ends up at its maximum does not test this:
    /// the shifter clamps its own property, so it lands there whatever it is
    /// handed. What has to hold is that the ratio survives the assignment
    /// untouched — the moment the shifter has to correct it, the landing pitch
    /// shown in the interface is a number the audio never reaches.
    func testTheBoundIsTheShiftersOwn() {
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)

        for (heard, target) in [(Float(90), Float(320)), (300, 70), (110, 200), (150, 150)] {
            let requested = VoiceChain.ratio(from: heard, to: target)
            shifter.pitchRatio = requested
            XCTAssertEqual(
                shifter.pitchRatio, requested, accuracy: 0.0001,
                "the shifter corrected \(requested) for \(heard) Hz to \(target) Hz"
            )
        }
    }
}
