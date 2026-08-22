import XCTest
@testable import KurarinDSP

final class NoiseReducerTests: XCTestCase {
    private func reducer(strength: Float, voiced: Bool = false) -> NoiseReducer {
        let unit = NoiseReducer(sampleRate: Signal.sampleRate)
        unit.strength = strength
        unit.isVoiced = voiced
        return unit
    }

    /// A fan or a preamp: broadband, steady, always there.
    private func steadyNoise(frames: Int, amplitude: Float = 0.05) -> [Float] {
        let lowPass = Biquad(sampleRate: Signal.sampleRate)
        lowPass.configure(kind: .lowpass, frequency: 6000, q: 0.707)
        return lowPass.process(Signal.noise(frames: frames, amplitude: amplitude))
    }

    private func voice(frames: Int, f0: Float = 130, amplitude: Float = 0.3) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        for harmonic in 1...8 {
            let partial = Signal.sine(
                frequency: f0 * Float(harmonic),
                frames: frames,
                amplitude: amplitude / Float(harmonic)
            )
            for i in 0..<frames { samples[i] += partial[i] }
        }
        return samples
    }

    /// Off has to mean off: a filterbank that colours the sound when it is
    /// doing nothing is one nobody can leave enabled.
    func testOffReconstructsTheInputExactly() {
        let input = voice(frames: 24000)
        let output = processStreaming(reducer(strength: 0), input)

        for i in input.indices {
            XCTAssertEqual(output[i], input[i], accuracy: 1e-6)
        }
    }

    /// Runs the unit block by block, telling it when a voice is present the
    /// way the chain does.
    private func run(
        _ unit: NoiseReducer,
        _ samples: [Float],
        voicedFrom: Int = .max,
        blockSize: Int = 256
    ) -> [Float] {
        var output = samples
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let frames = min(blockSize, buffer.count - offset)
                unit.isVoiced = offset >= voicedFrom
                unit.process(base + offset, frameCount: frames)
                offset += frames
            }
        }
        return output
    }

    /// The bands are differences of lowpasses so that they add back up. With
    /// every band left open the sum is the input again.
    func testBandsSumBackToTheInputWhenNothingIsReduced() {
        // Strength up but nothing to remove: a voice well above any floor.
        let unit = reducer(strength: 1, voiced: true)
        let input = voice(frames: 48000, amplitude: 0.4)
        let output = run(unit, input, voicedFrom: 0)

        // After the floors have settled, the loud parts come through whole.
        let tail = 24000..<47000
        XCTAssertEqual(
            Signal.rms(Array(output[tail])),
            Signal.rms(Array(input[tail])),
            accuracy: Signal.rms(Array(input[tail])) * 0.12
        )
    }

    func testSteadyNoiseIsBroughtDown() {
        let input = steadyNoise(frames: 96000)
        let output = processStreaming(reducer(strength: 1), input)

        // Measured once the floor has been learned.
        let before = Signal.rms(Array(input[48000...]))
        let after = Signal.rms(Array(output[48000...]))
        XCTAssertLessThan(after, before * 0.5, "the noise was barely touched")
    }

    /// The point of doing it per band: a second of room tone is enough to
    /// learn the noise, and then the voice arrives and survives it.
    func testAVoiceInNoiseKeepsItsLevel() {
        let frames = 144000
        let noise = steadyNoise(frames: frames, amplitude: 0.03)
        var samples = noise
        let clean = voice(frames: 96000)
        for i in 0..<96000 { samples[48000 + i] += clean[i] }

        let output = run(reducer(strength: 1), samples, voicedFrom: 48000)

        // The voice, measured where it is fully established.
        let range = 96000..<140000
        let voiceLevel = Signal.rms(Array(clean[(96000 - 48000)..<(140000 - 48000)]))
        let outputLevel = Signal.rms(Array(output[range]))
        XCTAssertGreaterThan(outputLevel, voiceLevel * 0.75, "the voice was reduced with the noise")

        // And the room tone before it is gone.
        let lead = 24000..<47000
        XCTAssertLessThan(
            Signal.rms(Array(output[lead])), Signal.rms(Array(samples[lead])) * 0.5,
            "the noise before the voice was not reduced"
        )
    }

    /// Between words is where the difference is heard.
    func testTheGapsBetweenWordsGetQuieter() {
        let frames = 144000
        var samples = steadyNoise(frames: frames, amplitude: 0.04)
        // A word in the middle third.
        let word = voice(frames: 48000)
        for i in 0..<48000 { samples[48000 + i] += word[i] }

        let output = processStreaming(reducer(strength: 1), samples)

        let gap = 120000..<143000
        let before = Signal.rms(Array(samples[gap]))
        let after = Signal.rms(Array(output[gap]))
        XCTAssertLessThan(after, before * 0.45)
    }

    func testSilenceInSilenceOut() {
        let output = processStreaming(reducer(strength: 1), Signal.silence(frames: 9600))
        XCTAssertEqual(Signal.peak(output), 0)
    }

    func testStaysFiniteAndBounded() {
        var samples = Signal.noise(frames: 96000, amplitude: 0.9)
        let word = voice(frames: 24000, amplitude: 0.8)
        for i in 0..<24000 { samples[24000 + i] += word[i] }

        let output = processStreaming(reducer(strength: 1), samples)
        XCTAssertTrue(Signal.isFinite(output))
        XCTAssertLessThan(Signal.peak(output), 4)
    }

    /// The host picks the block size, and how much noise gets removed must not
    /// depend on it.
    ///
    /// Not sample for sample: levels are measured per chunk, so a smaller chunk
    /// measures more often and the gain follows a slightly different path. What
    /// has to match is the result — the same noise, reduced by the same amount.
    func testBlockSizeDoesNotChangeHowMuchIsRemoved() {
        let input = steadyNoise(frames: 96000)
        let coarse = processStreaming(reducer(strength: 1), input, blockSize: 512)
        let fine = processStreaming(reducer(strength: 1), input, blockSize: 64)

        let range = 48000..<95000
        let coarseLevel = Signal.rms(Array(coarse[range]))
        let fineLevel = Signal.rms(Array(fine[range]))
        XCTAssertEqual(coarseLevel, fineLevel, accuracy: coarseLevel * 0.15)
    }

    /// Drives the reducer with the voicing verdict the chain would give it,
    /// which is the only way the speech-protecting half of the design runs.
    private func reduce(_ input: [Float], strength: Float, voicedFrom: Int) -> [Float] {
        let reducer = NoiseReducer(sampleRate: Signal.sampleRate)
        reducer.strength = strength
        var output = input
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let frames = min(256, buffer.count - offset)
                reducer.isVoiced = offset >= voicedFrom
                reducer.process(base + offset, frameCount: frames)
                offset += frames
            }
        }
        return output
    }

    private func level(_ samples: [Float], from low: Float, to high: Float) -> Float {
        let highPass = Biquad(sampleRate: Signal.sampleRate)
        highPass.configure(kind: .highpass, frequency: low, q: 0.707)
        let lowPass = Biquad(sampleRate: Signal.sampleRate)
        lowPass.configure(kind: .lowpass, frequency: high, q: 0.707)
        return Signal.rms(lowPass.process(highPass.process(samples)))
    }

    /// A second of room tone, then the same room tone with a tone over it.
    private func toneOverNoise(toneAmplitude: Float, noiseAmplitude: Float) -> (signal: [Float], half: Int) {
        let frames = 192000
        var signal = Signal.noise(frames: frames, amplitude: noiseAmplitude)
        let tone = Signal.sine(frequency: 1000, frames: frames, amplitude: toneAmplitude)
        for i in (frames / 2)..<frames { signal[i] += tone[i] }
        return (signal, frames / 2)
    }

    /// Subtracting in power rather than in amplitude is what separates cleaning
    /// a signal from thinning it, and it had nothing holding it in place.
    ///
    /// Measured where the two diverge most — a tone only a little above the
    /// floor. The tone loses 2.39 dB as it stands; subtracting the estimate
    /// from the amplitude instead costs 6.16 dB, and forgetting the square root
    /// alone costs 3.24. The bound sits under the nearer of those two.
    ///
    /// These numbers moved once already, when the neighbour averaging came out
    /// and every one of them dropped by half a decibel. If they move again,
    /// re-measure all three rather than nudging the bound — a threshold that no
    /// longer sits between them catches nothing.
    func testSpeechIsNotThinnedOutAlongWithTheNoise() {
        let (signal, half) = toneOverNoise(toneAmplitude: 0.05, noiseAmplitude: 0.05)
        let output = reduce(signal, strength: 0.7, voicedFrom: half)

        let window = (half + 24000)...
        let before = level(Array(signal[window]), from: 900, to: 1200)
        let after = level(Array(output[window]), from: 900, to: 1200)
        let lost = -20 * log10f(after / before)

        XCTAssertLessThan(lost, 2.9, "the signal was thinned, not cleaned: lost \(lost) dB")
        XCTAssertGreaterThan(lost, 0, "nothing happened at all, so this proves nothing")
    }

    /// Removing exactly the estimate leaves the noise audibly present, because
    /// the estimate is an average and the noise moves around it. Without the
    /// over-subtraction the same room tone comes out 10.4 dB down instead of
    /// 15.5.
    func testTheRoomToneIsRemovedRatherThanHalved() {
        let (signal, half) = toneOverNoise(toneAmplitude: 0.3, noiseAmplitude: 0.03)
        let output = reduce(signal, strength: 0.7, voicedFrom: half)

        let quiet = 24000..<half
        let before = level(Array(signal[quiet]), from: 900, to: 1200)
        let after = level(Array(output[quiet]), from: 900, to: 1200)
        let cut = -20 * log10f(after / before)

        XCTAssertGreaterThan(cut, 13, "the floor was only halved: cut \(cut) dB")
    }
}
