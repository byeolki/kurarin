@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import KurarinDSP
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

    /// What the computer is playing, from ScreenCaptureKit.
    ///
    /// Needed as well as the voice, not instead of it. The transformed voice
    /// never reaches the speakers — it goes to the virtual microphone — so
    /// nothing capturing system output can hear it, and a recording made only
    /// that way has a picture of a game with no one talking over it. The two
    /// are added together on the way to the file.
    private let systemAudio = SampleRing()
    /// Read into while mixing, on the way out.
    private var systemScratch: UnsafeMutablePointer<Float>
    /// Written into while taking a channel out of an interleaved block, on the
    /// way in. Separate from the one above so that neither has to know when the
    /// other is in use.
    private var downmix: UnsafeMutablePointer<Float>

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?

    /// The two sources are each within range on their own and can be over it
    /// together: the voice mix arrives limited to half a decibel under full
    /// scale, and whatever the computer is playing is added on top of that.
    /// Measured at 1.01 before this was here, which the AAC encoder clips.
    private let limiter: Limiter

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
        limiter = Limiter(sampleRate: Float(sampleRate))
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
        systemScratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        systemScratch.initialize(repeating: 0, count: scratchCapacity)
        downmix = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        downmix.initialize(repeating: 0, count: scratchCapacity)
        super.init()
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
        systemScratch.deinitialize(count: scratchCapacity)
        systemScratch.deallocate()
        downmix.deinitialize(count: scratchCapacity)
        downmix.deallocate()
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
        // A QuickTime file keeps the index that makes it playable at the end,
        // written when the recording is finished — so anything that stops the
        // app before that leaves a file of the right size that will not open.
        // Fragments close that index every second instead, which costs a little
        // size and means a recording interrupted by a crash, a force quit or a
        // power cut still plays up to its last second.
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

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
        systemSamplesSeen = 0
        framesReceived = 0
        framesDropped = 0
        framesRepeated = 0
        streamFailure = nil
        lastFrame = nil
        lastFrameAt = .invalid
        limiter.reset()
        audio.reset()
        systemAudio.reset()

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        // The computer's own sound: the game, the music, the call. Excluding
        // our own process keeps the soundboard and the monitoring out of it —
        // the soundboard is already in the mix we supply, and the monitoring is
        // the user's own voice coming back, which would double it.
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(sampleRate)
        configuration.channelCount = 1

        // A delegate, so that a stream which stops on its own says so. Without
        // one the frames simply cease and the recording quietly becomes a
        // still picture for the rest of its length.
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
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

    /// Closes the file from a thread that is about to be taken away.
    ///
    /// The async `stop` cannot be used while quitting: it hops to the main
    /// actor, and anything waiting for it there has already blocked the thread
    /// that would run it. This finishes on AVFoundation's own queue and waits
    /// on a semaphore, which is safe from any thread including that one.
    public func finishSynchronously(timeout: TimeInterval = 5) {
        guard isRecording else { return }
        isRecording = false

        if let stream {
            let stopped = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in stopped.signal() }
            _ = stopped.wait(timeout: .now() + 2)
        }
        self.stream = nil
        audioTimer?.cancel()
        audioTimer = nil

        queue.sync { drainAudio() }

        guard let writer, writer.status == .writing else {
            outputURL = nil
            self.writer = nil
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        _ = finished.wait(timeout: .now() + timeout)

        if writer.status != .completed, let url = outputURL {
            try? FileManager.default.removeItem(at: url)
            outputURL = nil
        }
        self.writer = nil
        videoInput = nil
        audioInput = nil
    }

    /// Drops everything without finishing the file, the way a process being
    /// killed does. Only for proving that a recording survives that.
    func abandonForTesting() {
        isRecording = false
        audioTimer?.cancel()
        audioTimer = nil
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
    }

    public func stop() async {
        guard isRecording else { return }
        isRecording = false

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
            // Say which it was. A writer that never started and one that gave
            // up part way through are different faults and the difference is
            // invisible from the file.
            if let writer, failure == nil {
                failure = .finishFailed(
                    writer.error.map { String(describing: $0) }
                        ?? "the writer was in state \(writer.status.rawValue) rather than writing"
                )
            }
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
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

    /// How much of the computer's own sound arrived while recording.
    ///
    /// Zero means ScreenCaptureKit handed over nothing at all, which is a
    /// different fault from handing over silence — the first is the capture not
    /// working, the second is nothing having been playing.
    public private(set) var systemSamplesSeen = 0

    /// Video frames handed to us, and the ones the encoder had no room for.
    ///
    /// A recording that stops part way through still ends with a valid file,
    /// so the only visible symptom is a video that is shorter than the time it
    /// was recording for. These say whether the frames stopped arriving or
    /// stopped being accepted.
    public private(set) var framesReceived = 0
    public private(set) var framesDropped = 0
    public private(set) var framesRepeated = 0
    /// Set when ScreenCaptureKit gives up, which it otherwise does silently.
    public private(set) var streamFailure: String?

    /// The last frame that arrived, kept so it can be sent again.
    ///
    /// ScreenCaptureKit delivers a frame when the screen changes and says
    /// nothing when it does not — a still desktop produces no frames at all.
    /// Left alone that makes the video track as long as the last thing that
    /// moved rather than as long as the recording: thirty seconds of recording
    /// a static screen came out as a one second file, and a screen that never
    /// changed came out empty.
    private var lastFrame: CMSampleBuffer?
    private var lastFrameAt: CMTime = .invalid
    /// How long a still screen is allowed to go before the last frame is
    /// repeated. Short enough that the track never falls far behind, long
    /// enough that a moving screen never reaches it.
    private static let stillFrameInterval = CMTime(value: 1, timescale: 3)

    // MARK: - Audio

    /// The ring is drained on a timer rather than when video frames arrive: a
    /// still screen produces no frames, and the sound has to keep being written
    /// through it.
    private func startAudioPump() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.drainAudio()
            self?.holdTheLastFrame()
        }
        timer.resume()
        audioTimer = timer
    }

    /// Sends the last frame again when the screen has stopped changing, so the
    /// video track keeps pace with real time.
    ///
    /// The repeat is stamped one interval after the frame before it, not from
    /// a clock read here: the frames carry ScreenCaptureKit's own timebase, and
    /// a timestamp from a different one is either rejected — which fails the
    /// whole writer — or silently out of order. Stepping along the existing
    /// timeline keeps it monotonic by construction, and the pump runs often
    /// enough that stepping at this interval tracks real time.
    /// Records the first moment the writer is seen to have given up, and
    /// where — it can fail on its own between appends, and only the first
    /// report says anything about why.
    private func noteFailure(where place: String) {
        guard failure == nil, let writer, writer.status == .failed else { return }
        failure = .finishFailed(
            "\(place), \(String(format: "%.1f", Double(samplesWritten) / sampleRate))s in: "
            + (writer.error.map { String(describing: $0) } ?? "no reason given")
        )
    }

    private func holdTheLastFrame() {
        guard isRecording,
              let input = videoInput,
              let frame = lastFrame,
              lastFrameAt.isValid,
              input.isReadyForMoreMediaData
        else { return }

        // How far the sound has got is the one measure of elapsed time this
        // class can trust: it counts samples that actually happened.
        let audioNow = CMTime(value: samplesWritten, timescale: CMTimeScale(sampleRate))
        let next = CMTimeAdd(lastFrameAt, ScreenRecorder.stillFrameInterval)
        guard CMTimeCompare(audioNow, next) > 0,
              let repeated = ScreenRecorder.retimed(frame, to: next)
        else { return }

        if input.append(repeated) {
            framesRepeated += 1
            lastFrameAt = next
        } else {
            framesDropped += 1
        }
    }

    private func drainAudio() {
        guard let input = audioInput, let format = audioFormat, startedAt.isValid else { return }
        noteFailure(where: "the sound")

        while audio.available > 0, input.isReadyForMoreMediaData {
            let count = audio.read(into: scratch, count: scratchCapacity)
            guard count > 0 else { break }

            // Whatever the computer was playing over the same span, added in.
            // Paired by count rather than by timestamp: both sides are fed from
            // the same run of real time and neither can get ahead without the
            // other's ring reporting it, which is what droppedSamples is for.
            let system = systemAudio.read(into: systemScratch, count: count)
            for i in 0..<system { scratch[i] += systemScratch[i] }
            limiter.process(scratch, frameCount: count)

            if let buffer = makeSampleBuffer(count: count, format: format) {
                if !input.append(buffer) { noteFailure(where: "the sound") }
            }
            samplesWritten += Int64(count)
        }
    }

    /// Wraps `scratch` as a sample buffer the writer will accept.
    ///
    /// Built empty and then filled from an `AudioBufferList`, rather than by
    /// handing `CMSampleBufferCreate` a block buffer directly. The direct route
    /// produces something that looks right, is accepted by the first append,
    /// and fails the writer a fraction of a second later with nothing to say
    /// but OSStatus -16122 — which cost most of an afternoon to find.
    private func makeSampleBuffer(count: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: samplesWritten, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )

        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(scratch)
            )
        )
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: &list
        ) == noErr else { return nil }

        return sample
    }

    /// Copies one block of the computer's own sound into its ring.
    ///
    /// Asked for as mono at the engine's rate, so no conversion should be
    /// needed — but the configuration is a request rather than a guarantee, so
    /// anything arriving with more than one channel has its first taken rather
    /// than being interpreted as twice as much mono.
    private func takeSystemAudio(_ buffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let data = list.mBuffers.mData else { return }

        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let frames = Int(list.mBuffers.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }

        systemSamplesSeen += frames
        let samples = data.assumingMemoryBound(to: Float.self)
        if channels == 1 {
            systemAudio.write(samples, count: frames)
        } else {
            let taking = min(frames, scratchCapacity)
            for i in 0..<taking { downmix[i] = samples[i * channels] }
            systemAudio.write(downmix, count: taking)
        }
    }

    /// A copy of `frame` presented at `time`. Metadata only — the pixels are
    /// shared rather than copied.
    private static func retimed(_ frame: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: frame,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        ) == noErr else { return nil }
        return copy
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
        guard isRecording, CMSampleBufferGetNumSamples(buffer) > 0 else { return }

        if type == .audio {
            takeSystemAudio(buffer)
            return
        }
        guard type == .screen else { return }

        // ScreenCaptureKit delivers a frame on every tick of its clock, but
        // only some of them carry an image. When the screen has not changed it
        // sends one marked idle, with the pixels left out — and appending those
        // is what was killing the writer a fraction of a second into every
        // recording. Video on its own survives it; interleaved with audio the
        // writer gives up with nothing to say but OSStatus -16122.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)),
              status == .complete,
              CMSampleBufferGetImageBuffer(buffer) != nil
        else { return }
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
            // The session runs from zero and both tracks are stamped by how
            // far into the recording they are. Anchoring to the clock the
            // frames arrived on works too, but it means every timestamp is a
            // host time — nanoseconds since boot, a number in the quadrillions
            // — added to a count of audio samples at 48 kHz, and nothing about
            // the file is easier to reason about for it.
            writer.startSession(atSourceTime: .zero)
            startedAt = first
        }

        framesReceived += 1
        noteFailure(where: "the picture")

        let elapsed = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(buffer), startedAt)
        guard input.isReadyForMoreMediaData else {
            framesDropped += 1
            return
        }
        guard let stamped = ScreenRecorder.retimed(buffer, to: elapsed) else { return }
        input.append(stamped)
        lastFrame = stamped
        lastFrameAt = elapsed
    }
}

extension ScreenRecorder: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamFailure = error.localizedDescription
    }
}
