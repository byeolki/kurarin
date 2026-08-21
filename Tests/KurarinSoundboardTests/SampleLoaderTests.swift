import AVFoundation
import XCTest
@testable import KurarinSoundboard

/// The loader is the only place a soundboard file is decoded, and everything
/// downstream of it assumes the result is mono, at the engine's rate, and
/// finite. Nothing checked that.
final class SampleLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurarin-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a real audio file, because the point of these tests is the
    /// decode path and a synthesised array would skip it.
    @discardableResult
    private func write(
        name: String,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        seconds: Double,
        frequency: Double = 220
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channels
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frames = AVAudioFrameCount(sampleRate * seconds)
        let chunk = AVAudioFrameCount(4096)
        var written: AVAudioFrameCount = 0
        while written < frames {
            let count = min(chunk, frames - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            for channel in 0..<Int(channels) {
                let data = buffer.floatChannelData![channel]
                for i in 0..<Int(count) {
                    let t = Double(written) + Double(i)
                    data[i] = Float(0.5 * sin(2 * .pi * frequency * t / sampleRate))
                }
            }
            try file.write(from: buffer)
            written += count
        }
        return url
    }

    func testResamplesToTheEngineRate() throws {
        let url = try write(name: "tone.caf", sampleRate: 44100, channels: 1, seconds: 1)
        let samples = try SampleLoader.load(url, sampleRate: 48000)

        // A second of audio at the engine's rate, give or take the converter's
        // priming.
        XCTAssertEqual(Double(samples.count), 48000, accuracy: 2400)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite })
    }

    func testDownmixesToMono() throws {
        let url = try write(name: "stereo.caf", sampleRate: 48000, channels: 2, seconds: 0.5)
        let samples = try SampleLoader.load(url, sampleRate: 48000)

        XCTAssertEqual(Double(samples.count), 24000, accuracy: 1200)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThan(peak, 0.1, "a downmix of two identical channels should not be silent")
    }

    func testKeepsTheSignalRatherThanJustTheLength() throws {
        let url = try write(name: "audible.caf", sampleRate: 48000, channels: 1, seconds: 0.5)
        let samples = try SampleLoader.load(url, sampleRate: 48000)

        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrtf(sum / Float(samples.count))
        // A 0.5 amplitude sine is 0.354 RMS. Anything far below means the
        // decode dropped or zeroed most of the file.
        XCTAssertEqual(rms, 0.354, accuracy: 0.05)
    }

    func testRejectsAFileThatIsNotThere() {
        let url = directory.appendingPathComponent("absent.caf")
        XCTAssertThrowsError(try SampleLoader.load(url, sampleRate: 48000)) { error in
            guard case SampleLoaderError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    func testRejectsAFileLongerThanTheLimit() throws {
        let url = try write(
            name: "long.caf",
            sampleRate: 8000,
            channels: 1,
            seconds: SampleLoader.maximumSeconds + 5
        )
        XCTAssertThrowsError(try SampleLoader.load(url, sampleRate: 48000)) { error in
            guard case SampleLoaderError.tooLong = error else {
                return XCTFail("expected .tooLong, got \(error)")
            }
        }
    }
}
