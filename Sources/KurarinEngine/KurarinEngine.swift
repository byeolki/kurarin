import Foundation
import CoreAudio
import KurarinDSP
import KurarinSoundboard

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

    public private(set) var isRunning = false
    public private(set) var configuration = Configuration()

    /// Why system capture is not running, when the rest of the engine is.
    /// A refused permission or a tap that could not be built costs that one
    /// feature, so it is reported rather than thrown.
    public private(set) var captureFailure: String?

    /// Peak levels for the meters, updated once per callback.
    public private(set) var inputLevel: Float = 0
    public private(set) var outputLevel: Float = 0

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

        // A denied capture permission should cost the capture feature, not the
        // whole engine, so a failure here is logged into the tap being absent
        // rather than thrown.
        captureFailure = nil
        if let source = configuration.captureSource {
            do {
                tap = try SystemAudioTap(source: source)
            } catch {
                // Silently losing system capture leaves the user wondering why
                // nobody can hear their music.
                captureFailure = error.localizedDescription
            }
        }

        let device = try AggregateDevice(
            microphone: microphone,
            virtualDevice: virtualDevice,
            monitor: configuration.monitor,
            tap: tap,
            sampleRate: configuration.sampleRate
        )
        aggregate = device

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.deviceID, nil) {
            [weak self] _, inputData, _, outputData, _ in
            guard let self else { return }
            self.render(input: inputData, output: outputData)
        }
        guard status == noErr, let procID else {
            aggregate = nil
            throw AudioDeviceError.coreAudio(status, "Installing the render callback")
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(device.deviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(device.deviceID, procID)
            ioProcID = nil
            aggregate = nil
            throw AudioDeviceError.coreAudio(startStatus, "Starting the device")
        }

        isRunning = true
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
        soundboard.collectRetiredBuffers()
    }

    // MARK: - Render

    private func render(
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        guard let aggregate else { return }
        let layout = aggregate.layout

        let outputList = UnsafeMutableAudioBufferListPointer(output)
        guard let frames = outputList.first.map({
            Int($0.mDataByteSize) / (MemoryLayout<Float>.size * Int(max($0.mNumberChannels, 1)))
        }), frames > 0, frames <= KurarinEngine.maximumFrames else {
            ChannelRouter.silence(outputList)
            return
        }

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

        inputLevel = peak(voiceBuffer, frames: frames)

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
        outputLevel = peak(mixBuffer, frames: frames)

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
