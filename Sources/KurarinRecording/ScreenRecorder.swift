@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum RecordingError: Error, LocalizedError {
    case noDisplay
    case permissionDenied
    case writerFailed(String)
    case finishFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display to record."
        case .permissionDenied:
            return "Screen recording permission was refused. If no dialog appeared, macOS has remembered an earlier answer: turn Kurarin on in System Settings ▸ Privacy & Security ▸ Screen Recording, then try again."
        case .writerFailed(let reason):
            return "Could not write the recording: \(reason)."
        case .finishFailed(let reason):
            return "The recording could not be completed: \(reason). The file is unplayable."
        }
    }
}

/// Records the screen with the mix the listeners hear.
///
/// The audio does not come from the system. What a listener hears is the
/// engine's own output — the transformed voice, the soundboard and whatever is
/// being shared, after the limiter — and that never reaches the speakers, so
/// capturing system audio would record the wrong thing or nothing at all. The
/// engine writes its finished mix into a `SampleRing` and this drains it.
///
/// Video is ScreenCaptureKit's, which delivers frames on its own queue. Both
/// tracks are stamped from the same host clock so they stay in step.
public final class ScreenRecorder: NSObject, @unchecked Sendable {
    public private(set) var isRecording = false
    public private(set) var outputURL: URL?

    /// Filled by the audio thread while a recording is running. Owned by
    /// whoever is producing the sound, so that it can outlive any one
    /// recording and never has to be handed across threads.
    public let audio: SampleRing

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?

    private let sampleRate: Double
    private let queue = DispatchQueue(label: "com.byeolki.kurarin.recording")
    private var audioTimer: DispatchSourceTimer?

    /// Where the next block of audio belongs, counted in samples from the
    /// first video frame. Derived rather than taken from the clock: the ring
    /// hands over exactly the samples the engine produced, so counting them is
    /// what keeps the track the same length as the audio it contains.
    private var samplesWritten: Int64 = 0
    private var startedAt: CMTime = .invalid
    private var scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 16384

    public init(audio: SampleRing, sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
        self.audio = audio
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
        super.init()
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
    }

    // MARK: - Lifecycle

    public func start(to url: URL) async throws {
        guard !isRecording else { return }

        // Ask before trying. ScreenCaptureKit refuses without permission but
        // does not raise the prompt itself, so a first-time user would be told
        // they had denied something nobody ever asked them about.
        //
        // Off the main thread, because the request blocks until the dialog is
        // answered and answering it takes as long as a person takes. Called
        // where it is isolated to the interface, it freezes the window and the
        // menu bar until they decide.
        if !CGPreflightScreenCaptureAccess() {
            let granted = await Task.detached { CGRequestScreenCaptureAccess() }.value
            guard granted else { throw RecordingError.permissionDenied }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecordingError.permissionDenied
        }
        guard let display = content.displays.first else { throw RecordingError.noDisplay }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: display.width,
            AVVideoHeightKey: display.height,
        ])
        video.expectsMediaDataInRealTime = true

        let audioTrack = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audioTrack.expectsMediaDataInRealTime = true

        guard writer.canAdd(video), writer.canAdd(audioTrack) else {
            throw RecordingError.writerFailed("the file cannot hold these tracks")
        }
        writer.add(video)
        writer.add(audioTrack)

        self.writer = writer
        self.videoInput = video
        self.audioInput = audioTrack
        self.audioFormat = ScreenRecorder.monoFormat(sampleRate: sampleRate)
        samplesWritten = 0
        startedAt = .invalid
        audio.reset()

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        // Audio is ours, so ScreenCaptureKit is asked for pictures only.
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        outputURL = url
        isRecording = true
        startAudioPump()
    }

    /// Why the last recording failed, if it did. AVAssetWriter can accept
    /// every sample and still end in `.failed`, so finishing is not the same
    /// as succeeding and has to be asked about.
    public private(set) var failure: RecordingError?

    public func stop() async {
        guard isRecording else { return }
        isRecording = false
        failure = nil

        audioTimer?.cancel()
        audioTimer = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Whatever the engine produced in the last few milliseconds is still in
        // the ring, and the file is shorter than the recording without it.
        //
        // Handed to the queue rather than run on it synchronously: appending
        // can block while the encoder catches up, and this is called from the
        // interface, which would sit frozen behind it.
        await withCheckedContinuation { continuation in
            queue.async {
                self.drainAudio()
                continuation.resume()
            }
        }

        // Nothing was ever written if no frame arrived — a recording stopped
        // within a frame of starting, or a display that never produced one.
        // Finishing a writer that was never started does not throw, it aborts
        // the process, so this is the difference between an empty recording and
        // the app disappearing.
        //
        // No file to clean up: AVAssetWriter creates one at startWriting, which
        // is what never happened. Only the URL needs forgetting, so that
        // "Show in Finder" does not point at nothing.
        guard let writer, writer.status == .writing else {
            outputURL = nil
            self.writer = nil
            videoInput = nil
            audioInput = nil
            return
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        if writer.status != .completed {
            let reason = writer.error.map { String(describing: $0) } ?? "status \(writer.status.rawValue)"
            failure = .finishFailed(reason)
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
            outputURL = nil
        }
        self.writer = nil
        videoInput = nil
        audioInput = nil
    }

    /// Samples the recorder lost because the writer fell behind.
    public var droppedSamples: Int { audio.dropped }

    // MARK: - Audio

    /// The ring is drained on a timer rather than when video frames arrive: a
    /// still screen produces no frames, and the sound has to keep being written
    /// through it.
    private func startAudioPump() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drainAudio() }
        timer.resume()
        audioTimer = timer
    }

    private func drainAudio() {
        guard let input = audioInput, let format = audioFormat, startedAt.isValid else { return }

        while audio.available > 0, input.isReadyForMoreMediaData {
            let count = audio.read(into: scratch, count: scratchCapacity)
            guard count > 0 else { break }
            if let buffer = makeSampleBuffer(count: count, format: format) {
                input.append(buffer)
            }
            samplesWritten += Int64(count)
        }
    }

    private func makeSampleBuffer(count: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }

        guard CMBlockBufferReplaceDataBytes(
            with: scratch, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTimeAdd(
                startedAt,
                CMTime(value: samplesWritten, timescale: CMTimeScale(sampleRate))
            ),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    private static func monoFormat(sampleRate: Double) -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format
        )
        return format
    }
}

extension ScreenRecorder: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, isRecording, CMSampleBufferGetNumSamples(buffer) > 0 else { return }
        guard let writer, let input = videoInput else { return }

        // Both tracks are timed from the first frame that actually arrives.
        // Starting the session from the moment the button was pressed would
        // leave the file beginning with however long the capture took to warm
        // up, as silence against a frozen picture.
        if !startedAt.isValid {
            let first = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard writer.startWriting() else {
                return
            }
            writer.startSession(atSourceTime: first)
            startedAt = first
        }

        if input.isReadyForMoreMediaData {
            input.append(buffer)
        }
        if writer.status == .failed {
            // Carrying on appending to a writer that has given up produces a
            // file that looks the right size and cannot be opened.
            failure = .finishFailed(writer.error.map { String(describing: $0) } ?? "unknown")
        }
    }
}
