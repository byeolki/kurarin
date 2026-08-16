import XCTest
@testable import KurarinDSP

/// Nothing in the chain may add audible noise of its own.
///
/// Every unit here generates or reshapes noise on purpose, and each one was
/// caught adding far more of it than it replaced: the rebuilt high band by
/// thirteen decibels, the breath by another thirteen. Both were measurable and
/// neither was visible in any test that asked only whether the feature worked.
final class AddedNoiseTests: XCTestCase {
    private func chain(_ configure: (inout VoiceParameters) -> Void) -> VoiceChain {
        let chain = VoiceChain(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        var parameters = VoiceParameters()
        parameters.gateEnabled = false
        parameters.clickSuppression = 0
        parameters.noiseReduction = 0
        parameters.breathiness = 0
        parameters.highBandResynthesis = 0
        configure(&parameters)
        chain.apply(parameters)
        return chain
    }

    private func run(_ chain: VoiceChain, _ samples: [Float]) -> [Float] {
        processStreaming(Adapter(chain: chain), samples)
    }

    /// Harmonics reaching well past the split, which is what a real voice has
    /// and a handful of sine partials does not.
    private func voice(frames: Int, f0: Float = 120) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        for harmonic in 1...60 {
            let partial = Signal.sine(
                frequency: f0 * Float(harmonic),
                frames: frames,
                amplitude: 0.3 / Float(harmonic)
            )
            for i in 0..<frames { samples[i] += partial[i] }
        }
        return samples
    }

    private func above(_ samples: [Float], _ frequency: Float) -> Float {
        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .highpass, frequency: frequency, q: 0.707)
        return Signal.rms(filter.process(samples))
    }

    /// The rebuilt band replaces the air; it must not amplify it. The failure
    /// this pins down was an analysis split with no lower bound, which measured
    /// the crossover's residue of the vowel and reproduced it as hiss that grew
    /// with the voice.
    func testRebuildingTheHighBandDoesNotAddEnergy() {
        let input = voice(frames: 144000)
        let range = 96000..<140000

        let plain = run(chain { $0.pitchRatio = 1.55; $0.formantRatio = 1.18 }, input)
        let rebuilt = run(chain {
            $0.pitchRatio = 1.55
            $0.formantRatio = 1.18
            $0.highBandResynthesis = 0.85
        }, input)

        let before = above(Array(plain[range]), 5000)
        let after = above(Array(rebuilt[range]), 5000)
        XCTAssertLessThan(after, before * 1.6, "the rebuilt band added hiss to the voice")
    }

    /// Aspiration sits far below the vowel it accompanies. At nine tenths of the
    /// envelope it was arriving eleven decibels down, which is a hiss with a
    /// voice behind it rather than a breathy voice.
    func testBreathStaysWellBelowTheVoice() {
        let input = voice(frames: 96000)
        let range = 48000..<92000

        let dry = run(chain { $0.pitchRatio = 1 }, input)
        let breathy = run(chain { $0.pitchRatio = 1; $0.breathiness = 0.3 }, input)

        let added = above(Array(breathy[range]), 2000) - above(Array(dry[range]), 2000)
        let voiceLevel = Signal.rms(Array(dry[range]))
        XCTAssertLessThan(added, voiceLevel * 0.06, "the breath is louder than breath")
        XCTAssertGreaterThan(added, 0, "no breath was added at all")
    }

    /// Only voiced audio is repeated by the shifter, so only voiced audio needs
    /// rebuilding. An "s" is mostly this band, and replacing it with an
    /// approximation is something the listener hears immediately.
    func testUnvoicedAudioIsNotRebuilt() {
        let shaper = HighBandShaper(sampleRate: Signal.sampleRate, delayFrames: 256)
        shaper.mix = 1
        shaper.isVoiced = false

        let highPass = Biquad(sampleRate: Signal.sampleRate)
        highPass.configure(kind: .highpass, frequency: HighBandShaper.splitHz, q: 0.707)
        let input = highPass.process(Signal.noise(frames: 24000, amplitude: 0.4))

        let output = processStreaming(shaper, input)
        for i in 12000..<24000 {
            XCTAssertEqual(output[i], input[i - 256], accuracy: 1e-5)
        }
    }
}

private final class Adapter: AudioProcessor {
    private let chain: VoiceChain
    init(chain: VoiceChain) { self.chain = chain }
    func reset() { chain.reset() }
    func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        chain.process(buffer, frameCount: frameCount)
    }
}
