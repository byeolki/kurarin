import XCTest
@testable import KurarinDSP

final class HighBandShaperTests: XCTestCase {
    private func shaper(mix: Float, formant: Float = 1, delay: Int = 1920) -> HighBandShaper {
        let unit = HighBandShaper(sampleRate: Signal.sampleRate, delayFrames: delay)
        unit.mix = mix
        unit.formantRatio = formant
        return unit
    }

    /// What the chain hands it: everything above the split.
    private func airBand(frames: Int, amplitude: Float = 0.3, seed: UInt64 = 7) -> [Float] {
        let highPass = Biquad(sampleRate: Signal.sampleRate)
        highPass.configure(kind: .highpass, frequency: HighBandShaper.splitHz, q: 0.707)
        return highPass.process(Signal.noise(frames: frames, amplitude: amplitude, seed: seed))
    }

    /// Spectral centre of gravity across the band, in hertz.
    ///
    /// A single crossover cannot tell this: most of the energy sits above any
    /// one edge either way, so the ratio barely moves. Weighting each slice by
    /// where it is can.
    private func centroid(_ samples: [Float]) -> Float {
        let edges: [Float] = [6000, 7500, 9000, 11000, 13500, 16500, 20000]
        var previous = [Float](repeating: 0, count: samples.count)
        var weighted: Float = 0
        var total: Float = 0
        var lastEdge: Float = HighBandShaper.splitHz * 0.5

        for edge in edges {
            let first = Biquad(sampleRate: Signal.sampleRate)
            first.configure(kind: .lowpass, frequency: edge, q: 0.707)
            let second = Biquad(sampleRate: Signal.sampleRate)
            second.configure(kind: .lowpass, frequency: edge, q: 0.707)
            let low = second.process(first.process(samples))

            let slice = (0..<samples.count).map { low[$0] - previous[$0] }
            let energy = Signal.rms(slice)
            let centre = (lastEdge + edge) * 0.5
            weighted += energy * centre
            total += energy
            previous = low
            lastEdge = edge
        }

        let top = (0..<samples.count).map { samples[$0] - previous[$0] }
        let topEnergy = Signal.rms(top)
        weighted += topEnergy * 22000
        total += topEnergy

        return total > 0 ? weighted / total : 0
    }

    func testOffIsAPlainDelay() {
        let unit = shaper(mix: 0, delay: 256)
        let input = airBand(frames: 4800)
        let output = processStreaming(unit, input)

        for i in 256..<input.count {
            XCTAssertEqual(output[i], input[i - 256], accuracy: 1e-6)
        }
    }

    /// Rebuilt rather than repeated, but it has to come back at the level it
    /// went in at.
    func testRebuiltBandKeepsTheLevel() {
        let input = airBand(frames: 96000)
        let output = processStreaming(shaper(mix: 1, delay: 1920), input)

        let range = 48000..<95000
        let before = Signal.rms(Array(input[range]))
        let after = Signal.rms(Array(output[range]))
        XCTAssertEqual(after, before, accuracy: before * 0.4)
    }

    /// The point of moving the synthesis bands: a smaller speaker's fricatives
    /// sit higher, and pitch alone never does that.
    func testFormantRatioMovesTheAirUpwards() {
        let input = airBand(frames: 96000)

        let plain = processStreaming(shaper(mix: 1, formant: 1), input)
        let smaller = processStreaming(shaper(mix: 1, formant: 1.4), input)

        let range = 48000..<95000
        let plainCentroid = centroid(Array(plain[range]))
        let smallerCentroid = centroid(Array(smaller[range]))

        XCTAssertGreaterThan(
            smallerCentroid, plainCentroid * 1.08,
            "raising the formant ratio did not move the noise up the spectrum "
                + "(\(Int(plainCentroid)) Hz to \(Int(smallerCentroid)) Hz)"
        )
    }

    /// It follows the envelope, so a fricative that stops has to stop.
    func testItStopsWhenTheInputStops() {
        var input = airBand(frames: 48000)
        input += Signal.silence(frames: 48000)

        let output = processStreaming(shaper(mix: 1, delay: 1920), input)

        let afterwards = Array(output[60000...])
        XCTAssertLessThan(
            Signal.rms(afterwards), Signal.rms(Array(output[24000..<47000])) * 0.05,
            "noise kept being generated after the input stopped"
        )
    }

    func testSilenceInSilenceOut() {
        let output = processStreaming(shaper(mix: 1), Signal.silence(frames: 9600))
        XCTAssertEqual(Signal.peak(output), 0)
    }

    func testStaysFiniteAndBounded() {
        let output = processStreaming(shaper(mix: 1, formant: 2), airBand(frames: 48000, amplitude: 0.9))
        XCTAssertTrue(Signal.isFinite(output))
        XCTAssertLessThan(Signal.peak(output), 4)
    }
}

/// The findings from reviewing this unit, kept as tests.
extension HighBandShaperTests {
    /// The generated noise is white before it is shaped, and the telescoping
    /// split assumes its source starts at the split. Without band limiting it
    /// first, the lowest sub-band reaches down to DC and lays rumble under the
    /// voice — measured at fifty decibels above the input below two hundred
    /// hertz.
    func testRebuiltBandAddsNothingBelowTheSplit() {
        let input = airBand(frames: 96000)
        let output = processStreaming(shaper(mix: 1, delay: 1920), input)

        func belowLevel(_ samples: [Float], _ frequency: Float) -> Float {
            let filter = Biquad(sampleRate: Signal.sampleRate)
            filter.configure(kind: .lowpass, frequency: frequency, q: 0.707)
            let second = Biquad(sampleRate: Signal.sampleRate)
            second.configure(kind: .lowpass, frequency: frequency, q: 0.707)
            return Signal.rms(second.process(filter.process(samples)))
        }

        let range = 48000..<95000
        for edge in [200, 1000, 3000] as [Float] {
            let before = belowLevel(Array(input[range]), edge)
            let after = belowLevel(Array(output[range]), edge)
            XCTAssertLessThan(
                after, max(before * 4, 1e-4),
                "the rebuilt band leaked energy below \(Int(edge)) Hz"
            )
        }
    }

    /// A deepened voice moves the air down, and the sub-bands have to move with
    /// it rather than collapsing onto the split.
    func testDeepeningKeepsTheAirRatherThanDroppingIt() {
        let input = airBand(frames: 96000)
        let deep = processStreaming(shaper(mix: 1, formant: 0.6), input)

        let range = 48000..<95000
        XCTAssertGreaterThan(
            Signal.rms(Array(deep[range])),
            Signal.rms(Array(input[range])) * 0.3,
            "the air was dropped instead of moved down"
        )
    }
}
