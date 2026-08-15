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
}
