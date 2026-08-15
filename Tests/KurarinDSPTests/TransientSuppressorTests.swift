import XCTest
@testable import KurarinDSP

final class TransientSuppressorTests: XCTestCase {
    private let sampleRate = Signal.sampleRate

    /// A key press or a mouse click: a couple of milliseconds of broadband
    /// energy with an instant attack.
    private func click(at position: Int, in samples: inout [Float], amplitude: Float = 0.9) {
        let length = Int(sampleRate * 0.003)
        let noise = Signal.noise(frames: length, amplitude: amplitude, seed: UInt64(position))
        for i in 0..<length where position + i < samples.count {
            // Sharp attack, quick decay — the shape of something hitting
            // something else.
            let decay = expf(-Float(i) / (sampleRate * 0.0008))
            samples[position + i] += noise[i] * decay
        }
    }

    /// A held vowel: a fundamental with harmonics, swelling and fading the way
    /// a person actually holds a note.
    private func heldVowel(frames: Int, frequency: Float = 130) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        for harmonic in 1...5 {
            let partial = Signal.sine(
                frequency: frequency * Float(harmonic),
                frames: frames,
                amplitude: 0.35 / Float(harmonic)
            )
            for i in 0..<frames { samples[i] += partial[i] }
        }
        // A slow swell, which is what makes naive suppressors treat the middle
        // of a held note as an onset.
        for i in 0..<frames {
            let t = Float(i) / Float(frames)
            samples[i] *= 0.4 + 0.6 * sinf(.pi * t)
        }
        return samples
    }

    private func suppressor(strength: Float, voiced: Bool) -> TransientSuppressor {
        let unit = TransientSuppressor(sampleRate: sampleRate)
        unit.strength = strength
        unit.isVoiced = voiced
        return unit
    }

    func testQuietensAClickAgainstRoomTone() {
        var samples = Signal.noise(frames: 24000, amplitude: 0.01)   // room tone
        click(at: 12000, in: &samples)

        let before = Signal.peak(Array(samples[11800..<13000]))
        let output = processStreaming(suppressor(strength: 1, voiced: false), samples)
        let after = Signal.peak(Array(output[11800..<13000]))

        XCTAssertLessThan(after, before * 0.35, "the click was not brought down")
    }

    /// The point of the whole unit: a held note must survive, including its
    /// swell, which is what most suppressors mistake for an onset.
    func testLeavesAHeldVowelAlone() {
        let vowel = heldVowel(frames: 48000)

        let output = processStreaming(suppressor(strength: 1, voiced: true), vowel)

        // Compared after the delay line, and away from the very start, where
        // the unit is still filling.
        let originalTail = Signal.rms(Array(vowel[24000..<47000]))
        let processedTail = Signal.rms(Array(output[24000..<47000]))
        XCTAssertEqual(processedTail, originalTail, accuracy: originalTail * 0.06)
    }

    /// The onset of speech after a silence is not a click, however sudden it
    /// looks against nothing at all.
    func testDoesNotSwallowTheStartOfAWord() {
        var samples = Signal.silence(frames: 12000)
        samples += heldVowel(frames: 24000, frequency: 160)

        let output = processStreaming(suppressor(strength: 1, voiced: true), samples)

        let originalOnset = Signal.rms(Array(samples[12000..<16000]))
        let processedOnset = Signal.rms(Array(output[12000..<16000]))
        XCTAssertGreaterThan(processedOnset, originalOnset * 0.7, "the first word was eaten")
    }

    /// A knock while talking is still worth reducing, just less aggressively:
    /// the ducking is audible against a voice, so the cure has to stay milder
    /// than the disease.
    func testStillReducesALoudKnockDuringSpeech() {
        var samples = heldVowel(frames: 36000)
        click(at: 18000, in: &samples, amplitude: 1.6)

        let before = Signal.peak(Array(samples[17800..<19000]))
        let output = processStreaming(suppressor(strength: 1, voiced: true), samples)
        let after = Signal.peak(Array(output[17800..<19000]))

        XCTAssertLessThan(after, before * 0.85)
    }

    func testOffLeavesTheSignalAloneApartFromItsDelay() {
        let unit = suppressor(strength: 0, voiced: false)
        let input = Signal.sine(frequency: 220, frames: 4800)
        let output = processStreaming(unit, input)

        // Delayed by exactly the look-ahead, and otherwise identical.
        let delay = unit.lookaheadFrames
        for i in delay..<input.count {
            XCTAssertEqual(output[i], input[i - delay], accuracy: 1e-6)
        }
    }

    func testStaysFiniteAndBounded() {
        var samples = Signal.noise(frames: 48000, amplitude: 0.8)
        for position in stride(from: 1000, to: 47000, by: 3000) {
            click(at: position, in: &samples, amplitude: 2)
        }

        let output = processStreaming(suppressor(strength: 1, voiced: false), samples)
        XCTAssertTrue(Signal.isFinite(output))
        XCTAssertLessThan(Signal.peak(output), 4)
    }

    func testSilenceInSilenceOut() {
        let output = processStreaming(suppressor(strength: 1, voiced: false), Signal.silence(frames: 4800))
        XCTAssertEqual(Signal.peak(output), 0)
    }
}
