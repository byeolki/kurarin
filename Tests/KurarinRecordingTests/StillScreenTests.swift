import AVFoundation
import XCTest
@testable import KurarinRecording

/// A screen that is not changing.
///
/// ScreenCaptureKit delivers a frame when the content changes and nothing when
/// it does not, so this is the ordinary case for anyone recording while they
/// talk over a static window — and the one that produced a one second file out
/// of a thirty second recording.
final class StillScreenTests: XCTestCase {
    func testTheVideoIsAsLongAsTheRecording() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurarin-still-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = ScreenRecorder(audio: SampleRing())
        do {
            try await recorder.start(to: url)
        } catch RecordingError.permissionDenied {
            throw XCTSkip("Screen recording permission has not been granted to the test runner.")
        }

        let seconds = 12.0
        var block = [Float](repeating: 0, count: 256)
        for i in 0..<Int(48000 * seconds / 256) {
            for j in 0..<256 { block[j] = 0.2 * sinf(Float(i * 256 + j) * 0.01) }
            block.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                recorder.audio.write(base, count: 256)
            }
            try await Task.sleep(nanoseconds: UInt64(256.0 / 48000 * 1e9))
        }

        await recorder.stop()

        print("STILL received=\(recorder.framesReceived) repeated=\(recorder.framesRepeated)"
              + " dropped=\(recorder.framesDropped) failure=\(recorder.failure.map(String.init(describing:)) ?? "none")"
              + " stream=\(recorder.streamFailure ?? "none") url=\(recorder.outputURL?.lastPathComponent ?? "nil")")

        XCTAssertNil(recorder.failure)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        print(String(format: "STILL duration %.2f s of %.0f s recorded", duration, seconds))

        XCTAssertGreaterThan(
            duration, seconds * 0.8,
            "the video is far shorter than the recording: a still screen stops producing frames"
        )
    }
}
