import XCTest
@testable import KurarinDSP

/// The two things that separate "a voice moved up" from "a different person":
/// where the pitch actually lands, and whether there is any breath in it.
final class VoiceIdentityTests: XCTestCase {
    private func speaker(f0: Float, frames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        for harmonic in 1...8 {
            let partial = Signal.sine(
                frequency: f0 * Float(harmonic),
                frames: frames,
                amplitude: 0.3 / Float(harmonic)
            )
            for i in 0..<frames { samples[i] += partial[i] }
        }
        return samples
    }

    private func chain(_ parameters: VoiceParameters) -> VoiceChain {
        let chain = VoiceChain(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        chain.apply(parameters)
        return chain
    }

    private func run(_ chain: VoiceChain, _ samples: [Float]) -> [Float] {
        processStreaming(ChainAdapter(chain: chain), samples)
    }

    /// The whole point of aiming at a frequency: two speakers an octave apart
    /// come out at the same place, which a fixed ratio can never do.
    func testTwoDifferentSpeakersLandOnTheSameTarget() {
        var parameters = VoiceParameters()
        parameters.targetPitchHz = 200
        parameters.gateEnabled = false
        parameters.breathiness = 0

        for sourceF0 in [100, 145] as [Float] {
            let voice = speaker(f0: sourceF0, frames: 480_000)   // ten seconds
            let chain = chain(parameters)
            let output = run(chain, voice)

            // Measured at the end, after the estimate has had time to settle.
            let tail = Array(output[400_000..<440_000])
            guard let heard = Signal.dominantFrequency(tail) else {
                return XCTFail("no pitch found in the output for \(sourceF0) Hz in")
            }
            XCTAssertEqual(heard, 200, accuracy: 25, "a \(sourceF0) Hz speaker did not reach the target")
        }
    }

    /// A target must not flatten the speech into a monotone: the estimate
    /// tracks the speaker, not the sentence.
    func testIntonationSurvivesATarget() {
        var parameters = VoiceParameters()
        parameters.targetPitchHz = 200
        parameters.gateEnabled = false
        parameters.breathiness = 0

        // A voice that rises through the utterance, as a question does.
        var samples: [Float] = []
        for step in 0..<10 {
            samples += speaker(f0: 110 + Float(step) * 6, frames: 24000)
        }

        let output = run(chain(parameters), samples)

        let early = Signal.dominantFrequency(Array(output[60_000..<90_000]))
        let late = Signal.dominantFrequency(Array(output[200_000..<230_000]))
        guard let early, let late else { return XCTFail("no pitch found") }

        XCTAssertGreaterThan(late, early * 1.1, "the rise was flattened out")
    }

    /// Without a target the preset's ratio is used unchanged, which is what an
    /// effect wants — a monster is a ratio, not a note.
    func testWithoutATargetTheRatioIsUsedAsGiven() {
        var parameters = VoiceParameters()
        parameters.pitchRatio = 0.6
        parameters.targetPitchHz = 0
        parameters.gateEnabled = false

        let chain = chain(parameters)
        _ = run(chain, speaker(f0: 120, frames: 96000))

        XCTAssertEqual(chain.effectivePitchRatio, 0.6, accuracy: 1e-6)
    }

    func testBreathAddsHighFrequencyNoiseOnlyWhileVoiced() {
        var parameters = VoiceParameters()
        parameters.breathiness = 0.8
        parameters.gateEnabled = false
        parameters.pitchRatio = 1
        parameters.formantRatio = 1

        let voice = speaker(f0: 130, frames: 96000)
        let dry = run(chain({ var p = parameters; p.breathiness = 0; return p }()), voice)
        let breathy = run(chain(parameters), voice)

        // The energy is added above the harmonics rather than under them.
        let highPass = Biquad(sampleRate: Signal.sampleRate)
        highPass.configure(kind: .highpass, frequency: 3000, q: 0.707)
        let dryHigh = Signal.rms(highPass.process(Array(dry[48000...])))

        let secondFilter = Biquad(sampleRate: Signal.sampleRate)
        secondFilter.configure(kind: .highpass, frequency: 3000, q: 0.707)
        let breathyHigh = Signal.rms(secondFilter.process(Array(breathy[48000...])))

        XCTAssertGreaterThan(breathyHigh, dryHigh * 2, "no breath was added")
    }

    func testBreathIsSilentWithoutAVoice() {
        var parameters = VoiceParameters()
        parameters.breathiness = 1
        parameters.gateEnabled = false

        let output = run(chain(parameters), Signal.silence(frames: 48000))
        XCTAssertEqual(Signal.peak(output), 0, "breath was audible with nothing to breathe under")
    }

    func testBreathStaysFinite() {
        var parameters = VoiceParameters()
        parameters.breathiness = 1
        let output = run(chain(parameters), Signal.noise(frames: 48000, amplitude: 0.9))
        XCTAssertTrue(Signal.isFinite(output))
        XCTAssertLessThan(Signal.peak(output), 4)
    }
}

private final class ChainAdapter: AudioProcessor {
    private let chain: VoiceChain
    init(chain: VoiceChain) { self.chain = chain }
    func reset() { chain.reset() }
    func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        chain.process(buffer, frameCount: frameCount)
    }
}
