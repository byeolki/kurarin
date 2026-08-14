import Foundation

/// The complete microphone processing chain.
///
/// Order is deliberate. The gate runs before the shifter so the shifter never
/// tries to find pitch in room tone. The high pass runs before it too, because
/// low-frequency rumble is what makes a pitch tracker report an octave too low.
/// EQ, drive and reverb run after, so they shape the voice the listener
/// actually hears rather than one that is about to be transformed again.
public final class VoiceChain {
    public let sampleRate: Float
    public private(set) var latencyMode: LatencyMode

    private let gate: NoiseGate
    private let highPass: Biquad
    private var shifter: VoiceShifter
    private let eq: ParametricEQ
    private let drive: Drive
    private let reverb: Reverb

    private var inputGain: Float = 1
    private var outputGain: Float = 1
    private var appliedHighPassHz: Float = 0

    public private(set) var parameters: VoiceParameters

    public init(sampleRate: Float, latencyMode: LatencyMode = .balanced) {
        self.sampleRate = sampleRate
        self.latencyMode = latencyMode

        gate = NoiseGate(sampleRate: sampleRate)
        highPass = Biquad(sampleRate: sampleRate)
        shifter = VoiceShifter(sampleRate: sampleRate, latencyMode: latencyMode)
        eq = ParametricEQ(sampleRate: sampleRate)
        drive = Drive(sampleRate: sampleRate)
        reverb = Reverb(sampleRate: sampleRate)

        parameters = VoiceParameters()
        apply(parameters)
    }

    /// Delay the chain introduces, in frames. Only the shifter contributes; the
    /// limiter lives downstream in the mixer.
    public var latencyFrames: Int { shifter.latencyFrames }

    /// Rebuilds the shifter for a new latency mode.
    ///
    /// Not real-time safe, and it drops the shifter's buffered audio, so the
    /// caller must stop the render callback first.
    public func setLatencyMode(_ mode: LatencyMode) {
        guard mode != latencyMode else { return }
        latencyMode = mode
        shifter = VoiceShifter(sampleRate: sampleRate, latencyMode: mode)
        apply(parameters)
    }

    /// Pushes a new parameter set into the units.
    ///
    /// Recomputes filter coefficients, so it runs on the parameter update path
    /// rather than inside the audio callback.
    public func apply(_ newParameters: VoiceParameters) {
        let clamped = newParameters.clamped()
        parameters = clamped

        inputGain = powf(10, clamped.inputGainDB / 20)
        outputGain = powf(10, clamped.outputGainDB / 20)

        gate.enabled = clamped.gateEnabled
        gate.thresholdDB = clamped.gateThresholdDB

        if clamped.highPassHz != appliedHighPassHz {
            highPass.configure(kind: .highpass, frequency: clamped.highPassHz, q: 0.707)
            appliedHighPassHz = clamped.highPassHz
        }

        shifter.pitchRatio = clamped.pitchRatio
        shifter.formantRatio = clamped.formantRatio

        eq.setBands(clamped.eqBands)

        drive.amount = clamped.driveAmount
        drive.bitDepth = clamped.driveBitDepth
        drive.downsampleHz = clamped.driveDownsampleHz
        drive.mix = clamped.driveMix

        reverb.roomSize = clamped.reverbRoomSize
        reverb.damping = clamped.reverbDamping
        reverb.mix = clamped.reverbMix
    }

    public func reset() {
        gate.reset()
        highPass.reset()
        shifter.reset()
        eq.reset()
        drive.reset()
        reverb.reset()
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        if inputGain != 1 {
            for i in 0..<frameCount { buffer[i] *= inputGain }
        }

        gate.process(buffer, frameCount: frameCount)
        highPass.process(buffer, frameCount: frameCount)
        shifter.process(buffer, frameCount: frameCount)
        eq.process(buffer, frameCount: frameCount)
        drive.process(buffer, frameCount: frameCount)
        reverb.process(buffer, frameCount: frameCount)

        if outputGain != 1 {
            for i in 0..<frameCount { buffer[i] *= outputGain }
        }
    }
}
