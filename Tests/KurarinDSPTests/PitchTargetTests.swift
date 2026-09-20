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

    /// What the shifter does before anyone has spoken.
    ///
    /// Aiming at a pitch means measuring the speaker first, and there is
    /// nothing to measure until they have said a couple of seconds' worth.
    /// Leaving the ratio alone until then left it at the shifter's built-in 1,
    /// so a preset with a target did nothing at all for the first seconds and
    /// nothing ever if the tracker never locked — a quiet microphone or a
    /// gate closing on the voice is enough for that. The preset's own ratio is
    /// the starting point instead, and the measurement takes over when it
    /// arrives.
    func testAimingAtAPitchStillShiftsBeforeItHasHeardAnything() {
        let chain = VoiceChain(sampleRate: Signal.sampleRate)
        var parameters = VoiceParameters()
        parameters.pitchRatio = 1.55
        parameters.formantRatio = 1.18
        parameters.targetPitchHz = 200
        chain.apply(parameters)

        XCTAssertEqual(
            chain.effectivePitchRatio, 1.55, accuracy: 0.001,
            "a preset that aims at a pitch does nothing until the speaker is measured"
        )

        // And the measurement still wins once there is one.
        var voice = [Float](repeating: 0, count: 48000 * 5)
        for harmonic in 1...10 {
            let partial = Signal.sine(
                frequency: 120 * Float(harmonic),
                frames: voice.count,
                amplitude: 0.5 * 0.35 / Float(harmonic)
            )
            for i in voice.indices { voice[i] += partial[i] }
        }
        _ = processStreaming(chain, voice)

        XCTAssertEqual(chain.detectedPitchHz, 120, accuracy: 6)
        XCTAssertEqual(
            chain.effectivePitchRatio, 200 / 120, accuracy: 0.08,
            "the measured ratio did not take over from the preset's"
        )
    }
}
