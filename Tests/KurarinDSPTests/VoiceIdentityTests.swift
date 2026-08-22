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

    /// The other half of the test below, which only ever fed it a voice.
    ///
    /// Breath belongs to a vowel. Adding it on unvoiced frames lays hiss over
    /// the fricatives, where there is already noise and none of it wants
    /// company — and the name of the test that was here promised this was
    /// checked when nothing checked it.
    func testBreathIsSilentOnUnvoicedFrames() {
        // The same signal both times, so the voicing flag is the only variable.
        // A voice rather than noise: the band the breath occupies has to be
        // quiet enough for an addition to it to show, and broadband noise fills
        // it already.
        var input = [Float](repeating: 0, count: 48000)
        for harmonic in 1...6 {
            let partial = Signal.sine(
                frequency: 130 * Float(harmonic),
                frames: 48000,
                amplitude: 0.35 / Float(harmonic)
            )
            for i in input.indices { input[i] += partial[i] }
        }

        func breath(voiced: Bool) -> [Float] {
            let unit = BreathGenerator(sampleRate: Signal.sampleRate)
            unit.amount = 0.8
            unit.isVoiced = voiced
            return processStreaming(unit, input)
        }

        func inBreathBand(_ samples: [Float]) -> Float {
            let highPass = Biquad(sampleRate: Signal.sampleRate)
            highPass.configure(kind: .highpass, frequency: 2200, q: 0.707)
            let lowPass = Biquad(sampleRate: Signal.sampleRate)
            lowPass.configure(kind: .lowpass, frequency: 4800, q: 0.707)
            return Signal.rms(lowPass.process(highPass.process(samples)))
        }

        // Past the blend ramp, so this is the settled state rather than the
        // fade into it.
        let tail = 24000...
        let dry = inBreathBand(Array(input[tail]))
        let unvoiced = inBreathBand(Array(breath(voiced: false)[tail]))
        let voiced = inBreathBand(Array(breath(voiced: true)[tail]))

        XCTAssertEqual(
            unvoiced, dry, accuracy: dry * 0.02,
            "breath was added on an unvoiced frame"
        )
        XCTAssertGreaterThan(
            voiced, dry * 1.05,
            "no breath was added even while voiced, so this proves nothing"
        )
    }

    func testBreathAddsHighFrequencyNoiseOnlyWhileVoiced() {
        var parameters = VoiceParameters()
        parameters.breathiness = 0.8
        parameters.gateEnabled = false
        parameters.pitchRatio = 1
        parameters.formantRatio = 1
        parameters.highBandResynthesis = 0

        let voice = speaker(f0: 130, frames: 96000)
        let dry = run(chain({ var p = parameters; p.breathiness = 0; return p }()), voice)
        let breathy = run(chain(parameters), voice)

        // Measured in the band the breath actually occupies. It stops below the
        // split, where the high band shaper takes over — two units adding noise
        // to the same octave is how a voice ends up sounding like a hiss with
        // words in it.
        func inBreathBand(_ samples: [Float]) -> Float {
            let highPass = Biquad(sampleRate: Signal.sampleRate)
            highPass.configure(kind: .highpass, frequency: 2200, q: 0.707)
            let lowPass = Biquad(sampleRate: Signal.sampleRate)
            lowPass.configure(kind: .lowpass, frequency: 4800, q: 0.707)
            return Signal.rms(lowPass.process(highPass.process(samples)))
        }

        let dryBand = inBreathBand(Array(dry[48000...]))
        let breathyBand = inBreathBand(Array(breathy[48000...]))

        XCTAssertGreaterThan(breathyBand, dryBand * 1.15, "no breath was added")
        // And it is breath, not a layer of hiss on top of the voice.
        XCTAssertLessThan(
            breathyBand - dryBand,
            Signal.rms(Array(dry[48000...])) * 0.1,
            "the breath is louder than breath"
        )
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
