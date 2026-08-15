import XCTest
@testable import KurarinDSP

/// Every unit that carries state between blocks has to reach silence, not
/// approach it forever.
///
/// A decaying tail that never quite arrives at zero ends up in the denormal
/// range, where the arithmetic runs in microcode at a fraction of the speed.
/// The symptom is a processor that gets slower minutes after the last sound —
/// dropouts with nothing on screen to explain them. Reaching exactly zero is
/// the observable form of "no denormals are being carried".
final class DenormalTests: XCTestCase {
    /// Feeds silence a second at a time until the output is exactly zero.
    ///
    /// Measured rather than assumed: how long a tail takes to fall through the
    /// whole normal range depends on the decay rate, and pinning a number into
    /// the test would only record today's reverb settings.
    private func secondsUntilExactSilence(
        _ unit: AudioProcessor,
        limit: Int = 60
    ) -> Int? {
        let second = Signal.silence(frames: Int(Signal.sampleRate))
        for elapsed in 1...limit {
            let output = processStreaming(unit, second)
            if (output.map(abs).max() ?? 0) == 0 { return elapsed }
        }
        return nil
    }

    private func excite(_ unit: AudioProcessor) {
        _ = processStreaming(unit, Signal.sine(frequency: 220, frames: 24000))
    }

    func testReverbTailReachesExactZero() {
        let reverb = Reverb(sampleRate: Signal.sampleRate)
        reverb.roomSize = 0.5
        reverb.damping = 0.2
        reverb.mix = 1
        excite(reverb)

        let seconds = secondsUntilExactSilence(reverb)
        XCTAssertNotNil(seconds, "the reverb tail never reached exact zero")
    }

    func testGateReachesExactZero() {
        let gate = NoiseGate(sampleRate: Signal.sampleRate)
        gate.thresholdDB = -45
        excite(gate)

        XCTAssertNotNil(secondsUntilExactSilence(gate, limit: 5))
    }

    func testFilterReachesExactZero() {
        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .lowShelf, frequency: 60, q: 0.707, gainDB: 12)
        excite(filter)

        XCTAssertNotNil(secondsUntilExactSilence(filter, limit: 5))
    }

    /// The direct form of the check: hand a unit values that are already
    /// denormal and make sure none of them survive into its state. This is the
    /// mechanism the long tails above rely on, and it runs in milliseconds.
    func testDenormalInputIsNotCarried() {
        let denormal = Float(1e-42)
        XCTAssertFalse(denormal.isNormal, "the test's own input is not denormal")

        for (label, unit) in units() {
            _ = processStreaming(unit, [Float](repeating: denormal, count: 4096))
            let output = processStreaming(unit, Signal.silence(frames: 32768))

            // The tail, not the whole block. A delay line already holding
            // denormal samples is entitled to play them out once — they are
            // audio, not state. What must not happen is that they are still
            // circulating several laps of the longest line later.
            let settled = output.suffix(8192)
            XCTAssertEqual(
                settled.map(abs).max() ?? 0, 0,
                "\(label) kept a denormal circulating in its state"
            )
        }
    }

    /// The chain as the engine runs it. The units feed each other, so one that
    /// keeps handing denormals downstream keeps the rest of them busy too.
    func testWholeChainReachesExactZero() {
        let chain = VoiceChain(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        var parameters = VoiceParameters()
        parameters.reverbMix = 0.6
        parameters.reverbRoomSize = 0.5
        parameters.driveAmount = 4
        chain.apply(parameters)

        let adapter = ChainAdapter(chain: chain)
        excite(adapter)

        XCTAssertNotNil(secondsUntilExactSilence(adapter), "the chain never reached exact zero")
    }

    private func units() -> [(String, AudioProcessor)] {
        let reverb = Reverb(sampleRate: Signal.sampleRate)
        reverb.mix = 1

        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .peaking, frequency: 1000, q: 4, gainDB: 12)

        let drive = Drive(sampleRate: Signal.sampleRate)
        drive.amount = 4
        drive.downsampleHz = 8000

        return [
            ("reverb", reverb),
            ("filter", filter),
            ("drive", drive),
            ("gate", NoiseGate(sampleRate: Signal.sampleRate)),
        ]
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
