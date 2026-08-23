import AVFoundation
import XCTest
@testable import KurarinRecording

/// Drives a whole recording: start, feed the ring the way the audio thread
/// would, stop, and then open the file and look at what came out.
///
/// Needs screen recording permission, and skips itself rather than failing when
/// it does not have it — a machine that has never granted it cannot run this
/// and that is not the code's fault.
final class ScreenRecorderTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurarin-recording-\(UUID().uuidString).mov")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testRecordsPictureAndSoundTogether() async throws {
        let recorder = ScreenRecorder(audio: SampleRing())

        do {
            try await recorder.start(to: url)
        } catch RecordingError.permissionDenied {
            throw XCTSkip("Screen recording permission has not been granted to the test runner.")
        }
        XCTAssertTrue(recorder.isRecording)

        // Two seconds of a tone, handed over in 256-frame blocks on a timer, the
        // way the render callback would.
        let seconds = 2.0
        let blockSize = 256
        let blocks = Int(48000 * seconds) / blockSize
        var phase: Float = 0
        var block = [Float](repeating: 0, count: blockSize)

        for _ in 0..<blocks {
            for i in 0..<blockSize {
                block[i] = 0.3 * sinf(phase)
                phase += 2 * .pi * 440 / 48000
            }
            block.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                recorder.audio.write(base, count: blockSize)
            }
            try await Task.sleep(nanoseconds: UInt64(Double(blockSize) / 48000 * 1e9))
        }

        await recorder.stop()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.failure, "the writer did not complete")

        // The file has to exist, hold both kinds of track, and be about as long
        // as the audio that went into it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "no file was written")

        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1, "no video track")
        XCTAssertEqual(audio.count, 1, "no audio track")

        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, seconds, accuracy: 1.0, "the file is not the length of the recording")

        let audioDuration = try await audio[0].load(.timeRange).duration.seconds
        XCTAssertGreaterThan(audioDuration, seconds * 0.6, "most of the sound is missing")

        XCTAssertEqual(recorder.droppedSamples, 0, "the ring overran during a two second recording")
    }

    /// Started and stopped before a single frame could arrive.
    ///
    /// Nothing has been written at that point, and asking AVAssetWriter to
    /// finish a session it never started aborts the process rather than
    /// returning an error — so this is the difference between an empty
    /// recording and the app vanishing while the user watches. Removing the
    /// guard makes this test die on signal 6.
    func testStoppingBeforeAnythingIsWrittenDoesNotCrash() async throws {
        let recorder = ScreenRecorder(audio: SampleRing())
        do {
            try await recorder.start(to: url)
        } catch RecordingError.permissionDenied {
            throw XCTSkip("Screen recording permission has not been granted to the test runner.")
        }
        await recorder.stop()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.outputURL, "a recording that never began still reports a file")
    }

    /// A recording the app never got to finish.
    ///
    /// The index a QuickTime file needs to be playable is written at the end,
    /// so anything that stops the process first — a crash, a force quit, the
    /// power going — used to leave a file of plausible size that would not
    /// open. Writing it in fragments closes that index every second instead.
    ///
    /// Simulated by abandoning the writer rather than killing the process:
    /// what matters is that nothing finished the file, which is the same
    /// condition.
    func testAnUnfinishedRecordingStillPlays() async throws {
        let recorder = ScreenRecorder(audio: SampleRing())
        do {
            try await recorder.start(to: url)
        } catch RecordingError.permissionDenied {
            throw XCTSkip("Screen recording permission has not been granted to the test runner.")
        }

        // Long enough for several fragments to have been closed.
        var block = [Float](repeating: 0.2, count: 256)
        for _ in 0..<(48000 * 3 / 256) {
            block.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                recorder.audio.write(base, count: 256)
            }
            try await Task.sleep(nanoseconds: UInt64(256.0 / 48000 * 1e9))
        }

        recorder.abandonForTesting()

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.5, "nothing survived the interruption")
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
    }
}
