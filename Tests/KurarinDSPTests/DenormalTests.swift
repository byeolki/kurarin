import XCTest
@testable import KurarinDSP

/// Every unit that carries state between blocks has to reach silence, not
/// approach it forever.
///
/// A decaying value that never quite arrives at zero ends up in the denormal
/// range, where the arithmetic runs in microcode at a fraction of the speed —
/// and the smallest denormal multiplied by a decay coefficient rounds back to
/// itself, so it stays there for as long as the app runs. The symptom would be
/// an audio thread that gets slower minutes after the last sound, with nothing
/// on screen to explain the dropouts.
///
/// These tests are written to fail if the flushing is removed, which is harder
/// than it sounds: a unit that only multiplies its input returns exact zeros
/// for silence no matter what state it is carrying, so the state has to be made
/// observable through a signal that is not silent.
final class DenormalTests: XCTestCase {
    private let denormal = Float(1e-42)

    func testTheTestsOwnDenormalIsActuallyDenormal() {
        XCTAssertFalse(denormal.isNormal)
        XCTAssertNotEqual(denormal, 0)
    }

    /// The gate's own state, because its output cannot report it: a gain stuck
    /// at the smallest denormal multiplied by any signal underflows to a clean
    /// zero, so a stalled gate and a silent one look identical from outside.
    ///
    /// Both values are exact fixed points once they reach the bottom of the
    /// denormal range — the smallest denormal times a decay coefficient rounds
    /// back to itself — so without flushing they would stay there for as long
    /// as the app runs.
    func testGateStateReachesExactZero() {
        let gate = NoiseGate(sampleRate: Signal.sampleRate)
        gate.thresholdDB = -30
        gate.releaseMs = 20

        // Open it, then leave it shut for long enough to decay all the way.
        _ = processStreaming(gate, Signal.sine(frequency: 220, frames: 4800))
        // Four seconds: the gain decays by about a thousandth per sample, so
        // it takes tens of thousands of them to fall through the whole normal
        // range and reach the denormals this is about.
        _ = processStreaming(gate, Signal.silence(frames: 192_000))

        XCTAssertEqual(gate.gain, 0, "the gate's gain stalled in the denormal range")
        XCTAssertEqual(gate.envelope, 0, "the gate's envelope stalled in the denormal range")
    }

    /// A gate that has been sitting under denormal input still has to open
    /// normally when a real signal arrives.
    func testGateStillOpensAfterAQuietStretch() {
        let gate = NoiseGate(sampleRate: Signal.sampleRate)
        gate.thresholdDB = -30
        _ = processStreaming(gate, [Float](repeating: denormal, count: 48000))

        let output = processStreaming(gate, Signal.sine(frequency: 220, frames: 24000))
        XCTAssertTrue(Signal.isFinite(output))
        XCTAssertGreaterThan(Signal.rms(output[12000...]), 0.2)
    }

    /// Units with a delay line: hand them values that are already denormal and
    /// check none are still circulating several laps of the longest line later.
    /// Decay-independent, and milliseconds to run.
    func testDenormalInputIsNotCarried() {
        for (label, unit) in unitsWithState() {
            _ = processStreaming(unit, [Float](repeating: denormal, count: 4096))
            let output = processStreaming(unit, Signal.silence(frames: 32768))

            // The tail, not the whole block. A delay line already holding
            // denormal samples is entitled to play them out once — they are
            // audio, not state. What must not happen is that they are still
            // going round.
            XCTAssertEqual(
                output.suffix(8192).map(abs).max() ?? 0, 0,
                "\(label) kept a denormal circulating in its state"
            )
        }
    }

    /// The whole chain, seeded the same way. The units feed each other, so one
    /// that keeps handing denormals downstream keeps the rest of them busy too.
    func testTheChainCarriesNoDenormals() {
        let chain = VoiceChain(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        var parameters = VoiceParameters()
        parameters.gateEnabled = false      // otherwise it simply mutes the seed
        parameters.reverbMix = 0.6
        parameters.reverbRoomSize = 0.9
        parameters.driveAmount = 4
        chain.apply(parameters)

        let adapter = ChainAdapter(chain: chain)
        _ = processStreaming(adapter, [Float](repeating: denormal, count: 8192))
        let output = processStreaming(adapter, Signal.silence(frames: 65536))

        XCTAssertEqual(
            output.suffix(8192).map(abs).max() ?? 0, 0,
            "the chain kept a denormal circulating"
        )
    }

    /// One end-to-end check that a real tail — not a seeded denormal — actually
    /// terminates. The room is deliberately small: the number of seconds this
    /// needs is a property of the decay rate, not of the flushing, and a long
    /// tail would only make the test slow to no purpose.
    func testAModestReverbTailTerminates() {
        let reverb = Reverb(sampleRate: Signal.sampleRate)
        reverb.roomSize = 0.5
        reverb.damping = 0.2
        reverb.mix = 1
        _ = processStreaming(reverb, Signal.sine(frequency: 220, frames: 24000))

        var reached = false
        let second = Signal.silence(frames: Int(Signal.sampleRate))
        for _ in 1...30 where !reached {
            reached = (processStreaming(reverb, second).map(abs).max() ?? 0) == 0
        }
        XCTAssertTrue(reached, "a room this size should fall silent well inside thirty seconds")
    }

    private func unitsWithState() -> [(String, AudioProcessor)] {
        let reverb = Reverb(sampleRate: Signal.sampleRate)
        reverb.mix = 1

        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .peaking, frequency: 1000, q: 4, gainDB: 12)

        let eq = ParametricEQ(sampleRate: Signal.sampleRate)
        eq.setBands(ParametricEQ.defaultBands.map {
            ParametricEQ.Band(frequency: $0.frequency, q: $0.q, gainDB: 6)
        })

        return [("reverb", reverb), ("filter", filter), ("equaliser", eq)]
    }
}

/// The chain is not an `AudioProcessor` itself — it owns them — but it has the
/// same shape, and the streaming helper wants one.
private final class ChainAdapter: AudioProcessor {
    private let chain: VoiceChain
    init(chain: VoiceChain) { self.chain = chain }
    func reset() { chain.reset() }
    func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        chain.process(buffer, frameCount: frameCount)
    }
}

/// Behaviour around the reverb being switched off, which is what a preset
/// change does.
final class ReverbBypassTests: XCTestCase {
    func testTurningTheReverbOffAndBackOnDoesNotReviveTheOldTail() {
        let reverb = Reverb(sampleRate: Signal.sampleRate)
        reverb.roomSize = 0.85
        reverb.damping = 0.3
        reverb.mix = 1

        // A room full of sound.
        _ = processStreaming(reverb, Signal.sine(frequency: 300, frames: 24000))

        // Off — as a preset without reverb leaves it.
        reverb.mix = 0
        let whileOff = processStreaming(reverb, Signal.silence(frames: 4800))
        XCTAssertEqual(Signal.peak(whileOff), 0, "a reverb that is off must be silent")

        // Back on, with nothing going in. Whatever comes out is the old room.
        reverb.mix = 1
        let afterReturning = processStreaming(reverb, Signal.silence(frames: 24000))
        XCTAssertEqual(Signal.peak(afterReturning), 0, "the previous tail came back")
    }

    func testTurningItOffDoesNotDisturbTheDrySignal() {
        let reverb = Reverb(sampleRate: Signal.sampleRate)
        reverb.mix = 0

        let input = Signal.sine(frequency: 440, frames: 4800)
        XCTAssertEqual(processStreaming(reverb, input), input)
    }
}
