import XCTest
@testable import KurarinDSP

/// What makes a shifted voice sound shifted.
///
/// The spectrum can be right and the pitch can be right and it can still be
/// obvious that a machine did it. The measurable part of that is what happens
/// to the noise: breath and fricative energy are aperiodic in a real voice, and
/// PSOLA raises pitch by laying the same glottal period down more often, which
/// repeats whatever noise was inside it and locks it to the new fundamental.
final class ShifterNaturalnessTests: XCTestCase {
    /// Highest normalised autocorrelation over a lag range — how periodic a
    /// signal is, from 0 (noise) to 1 (a perfect loop).
    private func periodicity(_ samples: [Float], lags: ClosedRange<Int>) -> Float {
        var best: Float = 0
        for lag in lags {
            var product: Float = 0, energyA: Float = 0, energyB: Float = 0
            for i in 0..<(samples.count - lag) {
                product += samples[i] * samples[i + lag]
                energyA += samples[i] * samples[i]
                energyB += samples[i + lag] * samples[i + lag]
            }
            let denominator = sqrtf(energyA * energyB)
            if denominator > 0 { best = max(best, product / denominator) }
        }
        return best
    }

    /// Harmonics with breath on top, which is what a voice is and what a bare
    /// sine is not.
    private func breathyVoice(f0: Float, frames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        for harmonic in 1...8 {
            let partial = Signal.sine(
                frequency: f0 * Float(harmonic),
                frames: frames,
                amplitude: 0.3 / Float(harmonic)
            )
            for i in 0..<frames { samples[i] += partial[i] }
        }

        let highPass = Biquad(sampleRate: Signal.sampleRate)
        highPass.configure(kind: .highpass, frequency: 3000, q: 0.707)
        let breath = highPass.process(Signal.noise(frames: frames, amplitude: 0.25))
        for i in 0..<frames { samples[i] += breath[i] }
        return samples
    }

    private func highBand(_ samples: [Float]) -> [Float] {
        let filter = Biquad(sampleRate: Signal.sampleRate)
        filter.configure(kind: .highpass, frequency: 3000, q: 0.707)
        return filter.process(samples)
    }

    /// A fricative has no glottal period, and the pitch control must therefore
    /// do nothing to it at all. The unvoiced path exists for that: fixed-length
    /// grains at their original spacing, so noise is resampled for formants and
    /// otherwise passed through.
    ///
    /// Level is what shows it. Run noise through at five pitch ratios and the
    /// output level does not move; take the unvoiced path away and it tracks
    /// the ratio, so an "s" gets quieter as the pitch slider goes up and louder
    /// as it comes down — 0.56 of the input at a ratio of 2, 1.11 at 0.5.
    ///
    /// Periodicity is not the measurement here, which is worth recording
    /// because it is the obvious one to reach for. Slicing noise on invented
    /// marks does stamp a period onto it, but the grain decorrelation added for
    /// breath already breaks that up, so the two mechanisms overlap and
    /// autocorrelation separates them barely at all.
    func testThePitchControlDoesNothingToAFricative() {
        let input = Signal.noise(frames: 96000, amplitude: 0.4)
        let reference = Signal.rms(Array(input[48000...]))
        var levels: [Float] = []

        for ratio in [Float(0.5), 0.7, 1.2, 1.5, 2.0] {
            let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
            shifter.pitchRatio = ratio
            shifter.formantRatio = 1

            let output = Array(processStreaming(shifter, input)[48000...])
            XCTAssertTrue(Signal.isFinite(output), "ratio \(ratio)")
            levels.append(Signal.rms(output) / reference)
        }

        let lowest = levels.min() ?? 0
        let highest = levels.max() ?? 0
        XCTAssertGreaterThan(lowest, 0.7, "the fricative was thinned out: \(levels)")
        XCTAssertLessThan(
            highest - lowest, 0.05,
            "the level of unpitched sound follows the pitch control: \(levels)"
        )
    }

    func testRaisingPitchDoesNotTurnBreathIntoABuzz() {
        let input = breathyVoice(f0: 120, frames: 96000)
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        shifter.pitchRatio = 1.5
        shifter.formantRatio = 1

        let output = processStreaming(shifter, input)

        let inputPeriodicity = periodicity(highBand(Array(input[48000...])), lags: 100...500)
        let outputPeriodicity = periodicity(highBand(Array(output[48000...])), lags: 100...500)

        XCTAssertLessThan(inputPeriodicity, 0.1, "the test's own breath is not aperiodic")
        // Without decorrelating the repeated grains this measures around 0.27,
        // sitting exactly on the shifted fundamental.
        XCTAssertLessThan(
            outputPeriodicity, 0.15,
            "the breath became periodic at the new pitch — the buzz is back"
        )
    }

    /// Decorrelation must not cost the thing the unit is for.
    func testPitchIsStillMovedAccurately() {
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        shifter.pitchRatio = 1.5
        shifter.formantRatio = 1

        let output = processStreaming(shifter, breathyVoice(f0: 120, frames: 96000))
        guard let heard = Signal.dominantFrequency(Array(output[48000...])) else {
            return XCTFail("no pitch in the output")
        }
        XCTAssertEqual(heard, 180, accuracy: 6)
    }

    /// Grains borrowed from earlier periods must not leave holes or steps in
    /// the level.
    func testLevelStaysSteadyWhileGrainsAreBorrowed() {
        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        shifter.pitchRatio = 1.6
        shifter.formantRatio = 1.15

        let output = processStreaming(shifter, breathyVoice(f0: 130, frames: 96000))

        var levels: [Float] = []
        for start in stride(from: 48000, to: 92000, by: 4000) {
            levels.append(Signal.rms(Array(output[start..<(start + 4000)])))
        }
        let quietest = levels.min() ?? 0
        let loudest = levels.max() ?? 0
        XCTAssertGreaterThan(quietest, loudest * 0.7, "the level wobbles as grains are borrowed")
    }

    /// A signal sitting on the edge of the voiced decision must not stutter
    /// between the two paths.
    func testMarginalVoicingDoesNotFlipEveryFrame() {
        // Harmonics buried in noise: the tracker will be unsure.
        var samples = Signal.noise(frames: 96000, amplitude: 0.25)
        for harmonic in 1...4 {
            let partial = Signal.sine(
                frequency: 140 * Float(harmonic),
                frames: 96000,
                amplitude: 0.12 / Float(harmonic)
            )
            for i in 0..<96000 { samples[i] += partial[i] }
        }

        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        shifter.pitchRatio = 1.4
        shifter.formantRatio = 1.1
        let output = processStreaming(shifter, samples)

        // Stuttering shows up as the level jumping between blocks.
        var levels: [Float] = []
        for start in stride(from: 48000, to: 94000, by: 2000) {
            levels.append(Signal.rms(Array(output[start..<(start + 2000)])))
        }
        let mean = levels.reduce(0, +) / Float(levels.count)
        let worst = levels.map { abs($0 - mean) }.max() ?? 0
        XCTAssertLessThan(worst, mean * 0.5, "the output level jumps as the voiced decision flips")
        XCTAssertTrue(Signal.isFinite(output))
    }

    /// Re-anchoring every analysis mark to the local peak is what stops the
    /// estimate's error compounding. Without it the marks slide off the pulses
    /// over a few dozen grains, the Hann window starts cutting the loudest part
    /// of each period, and the output goes quiet: 1.03 dB down over five
    /// seconds of a steady vowel, which is the whole of what the refinement
    /// buys and enough to hear as the voice sagging.
    func testMarksStayOnThePulsesInsteadOfSlidingOff() {
        var input = [Float](repeating: 0, count: 240000)
        for harmonic in 1...8 {
            let partial = Signal.sine(
                frequency: 120 * Float(harmonic),
                frames: 240000,
                amplitude: 0.3 / Float(harmonic)
            )
            for i in input.indices { input[i] += partial[i] }
        }

        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        shifter.pitchRatio = 1.4
        shifter.formantRatio = 1.15

        let output = Array(processStreaming(shifter, input)[48000...])
        let held = Signal.rms(output) / Signal.rms(Array(input[48000...]))

        XCTAssertGreaterThan(
            held, 0.75,
            "the output lost level over a steady vowel: \(20 * log10f(held)) dB"
        )
    }

    /// Real voices are not metronomes, and PSOLA is one unless it is told not
    /// to be: every synthesis mark lands exactly one advance after the last,
    /// so the output repeats itself perfectly for as long as the note is held.
    ///
    /// The jitter is only ±0.3% of a period, which is why this has to be
    /// measured a long way out. It is a random walk, so the disagreement
    /// accumulates: a hundred and forty periods along, the output's own
    /// autocorrelation is 0.932 with the jitter and 0.970 without it. At a
    /// fifth of that distance the two are 0.961 and 0.965 and nothing can be
    /// concluded, which is what a first attempt at this test measured.
    func testAHeldNoteDoesNotRepeatItselfExactly() {
        var input = [Float](repeating: 0, count: 400000)
        for harmonic in 1...8 {
            let partial = Signal.sine(
                frequency: 120 * Float(harmonic),
                frames: 400000,
                amplitude: 0.3 / Float(harmonic)
            )
            for i in input.indices { input[i] += partial[i] }
        }

        let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
        shifter.pitchRatio = 1.4
        shifter.formantRatio = 1

        let output = Array(processStreaming(shifter, input)[96000...])
        // A 120 Hz voice raised by 1.4 repeats every 285.7 samples, so the
        // hundred-and-fortieth repeat lands on 40000. Searching a narrow window
        // around it rather than a wide range keeps this test from costing half
        // a minute on its own.
        let repeated = periodicity(output, lags: 39900...40100)

        XCTAssertLessThan(
            repeated, 0.95,
            "the output repeats like a metronome nearly a second out: \(repeated)"
        )
        // Still a voice holding a note, not noise.
        XCTAssertGreaterThan(repeated, 0.7, "the output stopped being periodic at all")
    }

    /// Root mean square per five-millisecond window, expressed as a coefficient
    /// of variation — how much the output level wobbles over the course of a
    /// held note.
    private func envelopeVariation(_ samples: [Float]) -> Float {
        let window = 240
        let levels = stride(from: 0, to: samples.count - window, by: window).map {
            Signal.rms(Array(samples[$0..<($0 + window)]))
        }
        let mean = levels.reduce(0, +) / Float(levels.count)
        guard mean > 0 else { return 0 }
        let variance = levels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(levels.count)
        return sqrtf(variance) / mean
    }

    /// How steady the output is at the ratios where the shifter is cleanest.
    ///
    /// A synthesis mark almost never lands on a whole sample. `layDown` folds
    /// the remainder into the read position rather than rounding it away, so
    /// the grain is read from where the mark actually is. This is the only
    /// measurement that has been found to notice, and it only notices here:
    /// at 200 and 300 Hz doubled, the advance comes out very close to a whole
    /// number of samples and the residual wobble is a twentieth of what it is
    /// at neighbouring pitches, which leaves the rounding as the largest thing
    /// left in it. Round the mark instead and the two rise from 0.0029 and
    /// 0.0033 to 0.0035 and 0.0039.
    ///
    /// Everywhere else the difference disappears into effects an order of
    /// magnitude larger, which is why this is a bound on the two rather than a
    /// sweep. Level, envelope at other resolutions and energy below 80 Hz all
    /// come back identical either way.
    func testTheOutputIsSteadyWhereTheShifterIsCleanest() {
        var total: Float = 0

        for f0 in [Float(200), 300] {
            var input = [Float](repeating: 0, count: 200000)
            for harmonic in 1...8 {
                let partial = Signal.sine(
                    frequency: f0 * Float(harmonic),
                    frames: 200000,
                    amplitude: 0.3 / Float(harmonic)
                )
                for i in input.indices { input[i] += partial[i] }
            }

            let shifter = VoiceShifter(sampleRate: Signal.sampleRate, latencyMode: .balanced)
            shifter.pitchRatio = 2
            shifter.formantRatio = 2

            total += envelopeVariation(Array(processStreaming(shifter, input)[96000...]))
        }

        XCTAssertLessThan(
            total, 0.0068,
            "the output wobbles more than it should at its steadiest ratios: \(total)"
        )
    }
}
