import XCTest
@testable import KurarinDSP

/// The chain doing the two things that were asked of it together: take out the
/// keyboard, leave the voice — including the held vowel that every other noise
/// suppressor chews up.
final class NoiseHandlingTests: XCTestCase {
    private func chain(clickSuppression: Float, gate: Bool = true) -> ChainRunner {
        let chain = VoiceChain(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        var parameters = VoiceParameters()
        parameters.clickSuppression = clickSuppression
        parameters.gateEnabled = gate
        parameters.gateThresholdDB = -45
        chain.apply(parameters)
        return ChainRunner(chain: chain)
    }

    /// A voice: a fundamental with harmonics, held steady.
    private func voice(frames: Int, frequency: Float = 130, amplitude: Float = 0.3) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        for harmonic in 1...6 {
            let partial = Signal.sine(
                frequency: frequency * Float(harmonic),
                frames: frames,
                amplitude: amplitude / Float(harmonic)
            )
            for i in 0..<frames { samples[i] += partial[i] }
        }
        return samples
    }

    private func typing(into samples: inout [Float], every stride: Int, amplitude: Float) {
        let length = Int(Signal.sampleRate * 0.0025)
        for start in Swift.stride(from: stride, to: samples.count - length, by: stride) {
            let burst = Signal.noise(frames: length, amplitude: amplitude, seed: UInt64(start))
            for i in 0..<length {
                samples[start + i] += burst[i] * expf(-Float(i) / (Signal.sampleRate * 0.0006))
            }
        }
    }

    /// Typing into a quiet microphone, which is the case people actually
    /// complain about.
    func testTypingOverRoomToneIsBroughtDown() {
        var samples = Signal.noise(frames: 48000, amplitude: 0.004)
        typing(into: &samples, every: 6000, amplitude: 0.7)

        let untreated = chain(clickSuppression: 0).run(samples)
        let treated = chain(clickSuppression: 1).run(samples)

        XCTAssertLessThan(
            Signal.peak(treated), Signal.peak(untreated) * 0.5,
            "the typing was not brought down"
        )
    }

    /// The complaint this feature exists to answer: a held "aaah" must come
    /// through whole, even as it fades.
    func testAHeldVowelSurvivesWithSuppressionAtFull() {
        var samples = voice(frames: 60000)
        // Fading, which is where a gate normally cuts the tail off.
        for i in samples.indices {
            samples[i] *= 1 - 0.7 * Float(i) / Float(samples.count)
        }

        let plain = chain(clickSuppression: 0, gate: false).run(samples)
        let treated = chain(clickSuppression: 1).run(samples)

        // The last third: the quiet end of the note, after the gate has had
        // every opportunity to decide it is over.
        let range = 40000..<59000
        let plainTail = Signal.rms(Array(plain[range]))
        let treatedTail = Signal.rms(Array(treated[range]))
        XCTAssertGreaterThan(treatedTail, plainTail * 0.8, "the held note was cut short")
    }

    /// Both at once: the click goes, the vowel underneath it stays.
    func testAClickDuringAVowelDoesNotTakeTheVowelWithIt() {
        let clean = voice(frames: 48000)
        var withClick = clean
        typing(into: &withClick, every: 24000, amplitude: 1.4)

        let treated = chain(clickSuppression: 1).run(withClick)
        let reference = chain(clickSuppression: 1).run(clean)

        // Away from the click, the two have to be the same recording: the
        // suppressor must not leave a hole around what it removed.
        let away = 30000..<47000
        XCTAssertEqual(
            Signal.rms(Array(treated[away])),
            Signal.rms(Array(reference[away])),
            accuracy: Signal.rms(Array(reference[away])) * 0.1
        )
    }

    func testSuppressionOffLeavesTheChainLatencyUnchanged() {
        let quiet = VoiceChain(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        var off = VoiceParameters()
        off.clickSuppression = 0
        quiet.apply(off)

        let loud = VoiceChain(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        var on = VoiceParameters()
        on.clickSuppression = 1
        loud.apply(on)

        // Turning it on and off must not move the stream, so the delay it adds
        // is always in the count.
        XCTAssertEqual(quiet.latencyFrames, loud.latencyFrames)
    }
}

/// The chain is not an `AudioProcessor`; this gives the streaming helper
/// something with the right shape.
private final class ChainRunner {
    private let chain: VoiceChain
    init(chain: VoiceChain) { self.chain = chain }

    func run(_ samples: [Float]) -> [Float] {
        processStreaming(Adapter(chain: chain), samples)
    }

    private final class Adapter: AudioProcessor {
        private let chain: VoiceChain
        init(chain: VoiceChain) { self.chain = chain }
        func reset() { chain.reset() }
        func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
            chain.process(buffer, frameCount: frameCount)
        }
    }
}
