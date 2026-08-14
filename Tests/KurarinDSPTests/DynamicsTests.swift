import XCTest
@testable import KurarinDSP

final class NoiseGateTests: XCTestCase {
    func testClosesOnQuietSignal() {
        let gate = NoiseGate(sampleRate: Signal.sampleRate)
        gate.thresholdDB = -40
        gate.releaseMs = 10
        gate.holdMs = 0

        let quiet = Signal.sine(frequency: 300, frames: 24000, amplitude: 0.001)
        let output = gate.process(quiet)

        // Allow the release to finish before measuring.
        XCTAssertLessThan(Signal.rms(output[12000...]), 1e-5)
    }

    func testOpensOnLoudSignal() {
        let gate = NoiseGate(sampleRate: Signal.sampleRate)
        gate.thresholdDB = -40

        let loud = Signal.sine(frequency: 300, frames: 24000, amplitude: 0.5)
        let output = gate.process(loud)

        let settled = output[12000...]
        XCTAssertEqual(Signal.rms(settled), Signal.rms(loud), accuracy: Signal.rms(loud) * 0.05)
    }

    func testHysteresisPreventsChatterAtThreshold() {
        let gate = NoiseGate(sampleRate: Signal.sampleRate)
        gate.thresholdDB = -20
        gate.hysteresisDB = 6
        gate.holdMs = 50

        // Amplitude sits between the close and open thresholds, which is
        // exactly where a single-threshold gate would oscillate.
        let borderline = Signal.sine(frequency: 300, frames: 48000, amplitude: 0.07)
        let output = gate.process(borderline)

        XCTAssertTrue(Signal.isFinite(output))

        // Count how often the envelope crosses half its own peak. A chattering
        // gate produces many crossings; a stable one produces few.
        let peak = Signal.peak(output)
        guard peak > 0 else { return }
        var transitions = 0
        var wasAbove = false
        var blockStart = 0
        while blockStart + 480 <= output.count {
            let block = Array(output[blockStart..<(blockStart + 480)])
            let isAbove = Signal.rms(block) > peak * 0.25
            if isAbove != wasAbove { transitions += 1 }
            wasAbove = isAbove
            blockStart += 480
        }
        XCTAssertLessThanOrEqual(transitions, 2)
    }

    func testDisabledGateIsTransparent() {
        let gate = NoiseGate(sampleRate: Signal.sampleRate)
        gate.enabled = false
        let input = Signal.sine(frequency: 300, frames: 1024, amplitude: 0.0001)
        XCTAssertEqual(gate.process(input), input)
    }
}

final class LimiterTests: XCTestCase {
    func testNeverExceedsCeiling() {
        let limiter = Limiter(sampleRate: Signal.sampleRate)
        limiter.ceilingDB = -0.5

        let tooLoud = Signal.sine(frequency: 220, frames: 24000, amplitude: 4.0)
        let output = limiter.process(tooLoud)

        let ceiling = powf(10, -0.5 / 20)
        XCTAssertLessThanOrEqual(Signal.peak(output), ceiling * 1.001)
        XCTAssertTrue(Signal.isFinite(output))
    }

    func testCatchesTransientBeforeItArrives() {
        let limiter = Limiter(sampleRate: Signal.sampleRate)
        limiter.ceilingDB = -0.5

        // Silence, then a sudden full-scale burst. Without look-ahead the first
        // samples of the burst would pass through unattenuated.
        var input = Signal.silence(frames: 2000)
        input += Signal.sine(frequency: 500, frames: 4000, amplitude: 3.0)
        let output = limiter.process(input)

        let ceiling = powf(10, -0.5 / 20)
        XCTAssertLessThanOrEqual(Signal.peak(output), ceiling * 1.001)
    }

    func testQuietSignalPassesThroughUntouched() {
        let limiter = Limiter(sampleRate: Signal.sampleRate)
        let quiet = Signal.sine(frequency: 440, frames: 4800, amplitude: 0.2)
        let output = limiter.process(quiet)

        // Output is delayed by the look-ahead window, so compare settled regions.
        XCTAssertEqual(Signal.rms(output[2400...]), Signal.rms(quiet), accuracy: Signal.rms(quiet) * 0.02)
    }
}

final class DriveTests: XCTestCase {
    func testSaturationStaysBounded() {
        let drive = Drive(sampleRate: Signal.sampleRate)
        drive.amount = 12

        let output = drive.process(Signal.sine(frequency: 300, frames: 4800, amplitude: 0.9))
        XCTAssertTrue(Signal.isFinite(output))
        XCTAssertLessThanOrEqual(Signal.peak(output), 1.01)
    }

    func testBitCrushQuantises() {
        let drive = Drive(sampleRate: Signal.sampleRate)
        drive.bitDepth = 3

        let output = drive.process(Signal.sine(frequency: 300, frames: 4800))
        let distinct = Set(output.map { ($0 * 1000).rounded() })
        XCTAssertLessThan(distinct.count, 24)
    }

    func testNeutralSettingsAreTransparent() {
        let drive = Drive(sampleRate: Signal.sampleRate)
        let input = Signal.sine(frequency: 300, frames: 1024)
        XCTAssertEqual(drive.process(input), input)
    }
}

final class ReverbTests: XCTestCase {
    func testTailDecaysAfterImpulse() {
        let reverb = Reverb(sampleRate: Signal.sampleRate)
        reverb.mix = 0.6
        reverb.roomSize = 0.5

        var input = Signal.silence(frames: 96000)
        input[0] = 1
        let output = reverb.process(input)

        XCTAssertTrue(Signal.isFinite(output))
        let early = Signal.rms(output[1000..<10000])
        let late = Signal.rms(output[80000..<96000])
        XCTAssertGreaterThan(early, late)
    }

    func testDryMixIsTransparent() {
        let reverb = Reverb(sampleRate: Signal.sampleRate)
        reverb.mix = 0
        let input = Signal.sine(frequency: 300, frames: 1024)
        XCTAssertEqual(reverb.process(input), input)
    }
}
