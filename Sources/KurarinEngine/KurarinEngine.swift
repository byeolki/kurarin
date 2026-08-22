import Foundation
import CoreAudio
import os
import KurarinDSP
import KurarinSoundboard

/// Routing problems are invisible from the interface: a wrong channel offset
/// and a device that never started both look like a meter that does not move.
/// These go to the unified log, so `log stream --predicate 'subsystem ==
/// "com.byeolki.kurarin"'` says what the engine actually did.
///
/// Nothing here is called from the audio thread — os_log takes locks and can
/// allocate. What the callback has to report, it reports through counters the
/// main thread reads.
let engineLog = Logger(subsystem: "com.byeolki.kurarin", category: "engine")

/// Owns the audio graph: one callback on one aggregate device.
///
/// Reads the microphone, runs it through the voice chain, mixes in the
/// soundboard and the system audio tap, and writes the result to the virtual
/// device and to the monitoring output.
public final class KurarinEngine {
    public struct Configuration {
        public var microphone: AudioDeviceInfo?
        public var monitor: AudioDeviceInfo?
        public var captureSource: SystemAudioTap.Source?
        public var latencyMode: LatencyMode = .balanced
        public var sampleRate: Double = 48000

        public init() {}
    }

    /// Live controls. These are read by the audio thread and written by the UI.
    /// Plain stores of a Bool or a Float are atomic on every platform the app
    /// runs on, and the worst case is that a change lands one block later.
    public var isMuted = false
    public var monitorVoice = false
    public var monitorGain: Float = 1
    public var systemCaptureGain: Float = 1

    /// Correction for the microphone itself, applied before anything else.
    ///
    /// Belongs to the device rather than to a preset: how much gain a
    /// particular microphone needs is a fact about the hardware, and many USB
    /// microphones expose no software volume at all, so without this a quiet
    /// one has to be compensated for again in every preset the user owns.
    public var inputTrim: Float = 1

    public private(set) var isRunning = false
    public private(set) var configuration = Configuration()

    /// Why system capture is not running, when the rest of the engine is.
    /// A refused permission or a tap that could not be built costs that one
    /// feature, so it is reported rather than thrown.
    public private(set) var captureFailure: String?

    /// Highest peak since the last read, not the peak of the last callback.
    ///
    /// The callback runs about ninety times a second and the interface reads
    /// thirty times a second, so reporting only the most recent block throws
    /// away two thirds of the peaks — including, often, the loudest part of a
    /// syllable. Holding the maximum means a level that is read late is still
    /// the level that happened, and it stops the two meters from appearing to
    /// move in a different order each time, which is an artefact of sampling
    /// two fast-moving values at a slower rate.
    public private(set) var inputLevel: Float = 0

    /// Samples that arrived already at full scale, counted before any gain of
    /// ours is applied.
    ///
    /// Nothing downstream can undo this. A converter that ran out of range has
    /// flattened the tops off the waveform, and every stage after it — the
    /// shifter most of all, which repeats a period several times over — works
    /// with what is left and makes the damage more obvious rather than less.
    /// The only useful response is to tell whoever is speaking to turn the
    /// microphone's own gain down, and they cannot know to unless somebody
    /// says so.
    ///
    /// Written by the audio thread and read by the interface; a plain
    /// word-sized store, and a count that is one block stale says the same
    /// thing.
    public private(set) var clippedInputSamples = 0
    public private(set) var outputLevel: Float = 0

    /// Reads both meters and starts a fresh hold. Main thread only.
    public func drainLevels() -> (input: Float, output: Float) {
        let levels = (inputLevel, outputLevel)
        inputLevel = 0
        outputLevel = 0
        // Accumulated for the log, which runs right after a drain and would
        // otherwise only ever see the sliver of a block that arrived since.
        loggedInputPeak = max(loggedInputPeak, levels.0)
        loggedOutputPeak = max(loggedOutputPeak, levels.1)
        return levels
    }

    private var loggedInputPeak: Float = 0
    private var loggedOutputPeak: Float = 0

    public let soundboard = SoundboardMixer()
    public private(set) var chain: VoiceChain

    private var aggregate: AggregateDevice?
    private var tap: SystemAudioTap?
    private var ioProcID: AudioDeviceIOProcID?

    private static let maximumFrames = 8192
    private var voiceBuffer: UnsafeMutablePointer<Float>
    private var soundboardBuffer: UnsafeMutablePointer<Float>
    private var tapBuffer: UnsafeMutablePointer<Float>
    private var mixBuffer: UnsafeMutablePointer<Float>
    private let limiter: Limiter

    public init(sampleRate: Double = 48000) {
        chain = VoiceChain(sampleRate: Float(sampleRate), latencyMode: .balanced)
        limiter = Limiter(sampleRate: Float(sampleRate))

        voiceBuffer = .allocate(capacity: KurarinEngine.maximumFrames)
        soundboardBuffer = .allocate(capacity: KurarinEngine.maximumFrames)
        tapBuffer = .allocate(capacity: KurarinEngine.maximumFrames)
        mixBuffer = .allocate(capacity: KurarinEngine.maximumFrames)
        voiceBuffer.initialize(repeating: 0, count: KurarinEngine.maximumFrames)
        soundboardBuffer.initialize(repeating: 0, count: KurarinEngine.maximumFrames)
        tapBuffer.initialize(repeating: 0, count: KurarinEngine.maximumFrames)
        mixBuffer.initialize(repeating: 0, count: KurarinEngine.maximumFrames)
    }

    deinit {
        stop()
        voiceBuffer.deallocate()
        soundboardBuffer.deallocate()
        tapBuffer.deallocate()
        mixBuffer.deallocate()
    }

    /// Total delay from microphone to virtual device, in seconds.
    public var latencySeconds: Double {
        Double(chain.latencyFrames + limiter.lookaheadFrames) / configuration.sampleRate
    }

    public func apply(_ parameters: VoiceParameters) {
        chain.apply(parameters)
    }

    // MARK: - Lifecycle

    public func start(_ configuration: Configuration) throws {
        stop()

        guard let microphone = configuration.microphone ?? AudioDevices.defaultInputDevice() else {
            throw AudioDeviceError.deviceUnavailable("No input device")
        }
        guard let virtualDevice = AudioDevices.virtualDevice() else {
            throw AudioDeviceError.driverNotInstalled
        }

        self.configuration = configuration
        chain.setLatencyMode(configuration.latencyMode)
        chain.reset()
        limiter.reset()

        openTap(configuration.captureSource)
        logConfiguration(microphone: microphone, configuration: configuration)

        let device = try AggregateDevice(
            microphone: microphone,
            virtualDevice: virtualDevice,
            monitor: configuration.monitor,
            tap: tap,
            sampleRate: configuration.sampleRate
        )
        aggregate = device
        logLayout(of: device)

        do {
            ioProcID = try beginRendering(on: device)
        } catch {
            aggregate = nil
            throw error
        }

        isRunning = true
        engineLog.notice("engine running")
    }

    /// Opens the system capture tap, if one was asked for.
    ///
    /// A denied capture permission should cost the capture feature, not the
    /// whole engine, so a failure here is recorded in `captureFailure` rather
    /// than thrown — but it is recorded, because silently losing system
    /// capture leaves the user wondering why nobody can hear their music.
    private func openTap(_ source: SystemAudioTap.Source?) {
        captureFailure = nil
        guard let source else { return }
        do {
            tap = try SystemAudioTap(source: source)
        } catch {
            captureFailure = error.localizedDescription
        }
    }

    /// Installs the render callback and starts the device, leaving nothing
    /// behind if either step fails.
    private func beginRendering(on device: AggregateDevice) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.deviceID, nil) {
            [weak self] _, inputData, _, outputData, _ in
            guard let self else { return }
            self.render(input: inputData, output: outputData)
        }
        guard status == noErr, let procID else {
            engineLog.error("installing the render callback failed: \(status)")
            throw AudioDeviceError.coreAudio(status, "Installing the render callback")
        }

        let startStatus = AudioDeviceStart(device.deviceID, procID)
        guard startStatus == noErr else {
            engineLog.error("starting the aggregate failed: \(startStatus)")
            AudioDeviceDestroyIOProcID(device.deviceID, procID)
            throw AudioDeviceError.coreAudio(startStatus, "Starting the device")
        }
        return procID
    }

    private func logConfiguration(microphone: AudioDeviceInfo, configuration: Configuration) {
        engineLog.notice("""
            starting: microphone=\(microphone.name, privacy: .public) \
            (\(microphone.inputChannels)in/\(microphone.outputChannels)out) \
            monitor=\(configuration.monitor?.name ?? "none", privacy: .public) \
            (\(configuration.monitor?.outputChannels ?? 0)out) \
            capture=\(configuration.captureSource == nil ? "off" : "on", privacy: .public) \
            rate=\(configuration.sampleRate)
            """)
        if let captureFailure {
            engineLog.error("system capture unavailable: \(captureFailure, privacy: .public)")
        }
    }

    private func logLayout(of device: AggregateDevice) {
        let layout = device.layout
        engineLog.notice("""
            aggregate \(device.deviceID) built: \
            mic in \(layout.microphoneInputOffset)..<\
            \(layout.microphoneInputOffset + layout.microphoneChannels), \
            tap in \(layout.tapInputOffset)..<\(layout.tapInputOffset + layout.tapChannels), \
            virtual out \(layout.virtualOutputOffset)..<\
            \(layout.virtualOutputOffset + layout.virtualChannels), \
            monitor out \(layout.monitorOutputOffset)..<\
            \(layout.monitorOutputOffset + layout.monitorChannels)
            """)
    }

    /// What the callback has seen, for the interface to report. Written by the
    /// audio thread, read by the main thread; both are plain word-sized stores,
    /// and a count that is one block stale tells the same story.
    public private(set) var callbackCount = 0
    public private(set) var lastFrameCount = 0
    public private(set) var lastInputChannelCount = 0

    /// A line describing what the audio thread is actually doing. Called from
    /// the main thread on a timer, never from the callback.
    public func logActivity() {
        guard isRunning else { return }
        engineLog.notice("""
            callbacks=\(self.callbackCount) frames=\(self.lastFrameCount) \
            inputChannels=\(self.lastInputChannelCount) \
            peakIn=\(String(format: "%.4f", self.loggedInputPeak), privacy: .public) \
            peakOut=\(String(format: "%.4f", self.loggedOutputPeak), privacy: .public)
            """)
        loggedInputPeak = 0
        loggedOutputPeak = 0
    }

    public func stop() {
        if let aggregate, let ioProcID {
            AudioDeviceStop(aggregate.deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregate.deviceID, ioProcID)
        }
        ioProcID = nil
        aggregate?.destroy()
        aggregate = nil
        tap = nil
        isRunning = false
        inputLevel = 0
        outputLevel = 0
        clippedInputSamples = 0
        soundboard.collectRetiredBuffers()
    }

    // MARK: - Render

    /// Full scale rather than a threshold under it: a converter at its limit
    /// returns exactly ±1, and anything quieter is a signal that still has its
    /// shape.
    private func countClipping(in buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var count = 0
        for i in 0..<frames where abs(buffer[i]) >= 0.999 { count += 1 }
        clippedInputSamples += count
    }

    private func render(
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        guard let aggregate else { return }
        let layout = aggregate.layout
        callbackCount += 1

        let outputList = UnsafeMutableAudioBufferListPointer(output)
        guard let frames = outputList.first.map({
            Int($0.mDataByteSize) / (MemoryLayout<Float>.size * Int(max($0.mNumberChannels, 1)))
        }), frames > 0, frames <= KurarinEngine.maximumFrames else {
            ChannelRouter.silence(outputList)
            return
        }
        lastFrameCount = frames

        // Start from silence: an early return anywhere below must leave the
        // virtual device quiet rather than replaying whatever was in the buffer.
        ChannelRouter.silence(outputList)

        for i in 0..<frames {
            voiceBuffer[i] = 0
            soundboardBuffer[i] = 0
            tapBuffer[i] = 0
            mixBuffer[i] = 0
        }

        if let input {
            let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // Recorded rather than logged: if this is zero the aggregate handed
            // the callback no input at all, which is a different problem from
            // reading the wrong channels out of it.
            lastInputChannelCount = inputList.reduce(0) { $0 + Int($1.mNumberChannels) }
            ChannelRouter.readMono(
                from: inputList,
                channelOffset: layout.microphoneInputOffset,
                channelCount: layout.microphoneChannels,
                into: voiceBuffer,
                frames: frames
            )
            if layout.tapChannels > 0 {
                ChannelRouter.readMono(
                    from: inputList,
                    channelOffset: layout.tapInputOffset,
                    channelCount: layout.tapChannels,
                    into: tapBuffer,
                    frames: frames
                )
            }
        }

        // Before the trim, because this is a question about what the
        // microphone delivered rather than about what we did with it.
        countClipping(in: voiceBuffer, frames: frames)

        // Trim first, so the meter shows what the rest of the chain is working
        // with — including the gate, which is the thing most likely to be
        // deciding a quiet microphone is silence.
        let trim = inputTrim
        if trim != 1 {
            for i in 0..<frames { voiceBuffer[i] *= trim }
        }

        inputLevel = max(inputLevel, peak(voiceBuffer, frames: frames))

        if isMuted {
            for i in 0..<frames { voiceBuffer[i] = 0 }
        }
        // The chain runs even while muted so its delay lines stay primed and
        // unmuting resumes cleanly rather than from cold filters. Bypassing the
        // effect is a matter of applying neutral parameters, not of skipping
        // the chain, which would jump the stream by the shifter's latency.
        chain.process(voiceBuffer, frameCount: frames)
        if isMuted {
            for i in 0..<frames { voiceBuffer[i] = 0 }
        }

        soundboard.render(into: soundboardBuffer, frameCount: frames)

        // The three sources stay in their own buffers up to this point, because
        // the two destinations want different combinations of them.
        let captureGain = systemCaptureGain
        for i in 0..<frames {
            mixBuffer[i] = voiceBuffer[i] + soundboardBuffer[i] + tapBuffer[i] * captureGain
        }
        limiter.process(mixBuffer, frameCount: frames)
        outputLevel = max(outputLevel, peak(mixBuffer, frames: frames))

        ChannelRouter.write(
            mixBuffer,
            into: outputList,
            channelOffset: layout.virtualOutputOffset,
            channelCount: layout.virtualChannels,
            frames: frames,
            gain: 1
        )

        if layout.monitorChannels > 0 {
            // Monitoring gets the soundboard, and the voice only on request.
            // The tap is deliberately excluded: those applications are already
            // playing through these same headphones, so echoing them back would
            // double every sound the user hears.
            let includeVoice = monitorVoice
            for i in 0..<frames {
                mixBuffer[i] = soundboardBuffer[i] + (includeVoice ? voiceBuffer[i] : 0)
            }
            ChannelRouter.write(
                mixBuffer,
                into: outputList,
                channelOffset: layout.monitorOutputOffset,
                channelCount: layout.monitorChannels,
                frames: frames,
                gain: monitorGain
            )
        }
    }

    private func peak(_ buffer: UnsafePointer<Float>, frames: Int) -> Float {
        var result: Float = 0
        for i in 0..<frames {
            let magnitude = abs(buffer[i])
            if magnitude > result { result = magnitude }
        }
        return result.isFinite ? result : 0
    }

}
