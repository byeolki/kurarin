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
    private let suppressor: TransientSuppressor
    private let denoiser: NoiseReducer
    private let highPass: Biquad
    private var shifter: VoiceShifter
    /// One analysis, shared. The gate uses it to know a held note is still a
    /// note, the suppressor uses it to know a click is not one, and the shifter
    /// uses it to place its grains — all from the same verdict on the same
    /// samples, rather than three units each analysing a slightly different
    /// version of the signal.
    private let tracker: PitchTracker
    private var samplesSinceAnalysis = 0
    private let analysisHop: Int
    /// Splits the harmonic part of the voice from the air above it. The two
    /// need completely different treatment: one is repeated periodically by the
    /// shifter, the other must never be.
    private let splitFilters: [Biquad]
    private var highShaper: HighBandShaper
    private var lowScratch: [Float]
    private var highScratch: [Float]
    private static let maximumBlock = 8192

    private let formantCorrector: FormantCorrector
    private let breath: BreathGenerator
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

        tracker = PitchTracker(sampleRate: sampleRate, minimumHz: latencyMode.minimumPitchHz)
        analysisHop = latencyMode.hopSize

        gate = NoiseGate(sampleRate: sampleRate)
        suppressor = TransientSuppressor(sampleRate: sampleRate)
        denoiser = NoiseReducer(sampleRate: sampleRate)
        highPass = Biquad(sampleRate: sampleRate)
        shifter = VoiceShifter(sampleRate: sampleRate, latencyMode: latencyMode, tracker: tracker)
        splitFilters = (0..<2).map { _ in
            let filter = Biquad(sampleRate: sampleRate)
            filter.configure(kind: .lowpass, frequency: HighBandShaper.splitHz, q: 0.707)
            return filter
        }
        highShaper = HighBandShaper(sampleRate: sampleRate, delayFrames: shifter.latencyFrames)
        lowScratch = [Float](repeating: 0, count: VoiceChain.maximumBlock)
        highScratch = [Float](repeating: 0, count: VoiceChain.maximumBlock)

        formantCorrector = FormantCorrector(sampleRate: sampleRate)
        breath = BreathGenerator(sampleRate: sampleRate)
        eq = ParametricEQ(sampleRate: sampleRate)
        drive = Drive(sampleRate: sampleRate)
        reverb = Reverb(sampleRate: sampleRate)

        parameters = VoiceParameters()
        apply(parameters)
    }

    /// Delay the chain introduces, in frames. The limiter lives downstream in
    /// the mixer and is counted separately.
    public var latencyFrames: Int { shifter.latencyFrames + suppressor.lookaheadFrames }

    /// Rebuilds the shifter for a new latency mode.
    ///
    /// Not real-time safe, and it drops the shifter's buffered audio, so the
    /// caller must stop the render callback first.
    public func setLatencyMode(_ mode: LatencyMode) {
        guard mode != latencyMode else { return }
        latencyMode = mode
        shifter = VoiceShifter(sampleRate: sampleRate, latencyMode: mode, tracker: tracker)
        // The rebuilt band has to wait exactly as long as the shifted one.
        highShaper = HighBandShaper(sampleRate: sampleRate, delayFrames: shifter.latencyFrames)
        highShaper.formantRatio = parameters.formantRatio
        highShaper.mix = parameters.highBandResynthesis
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
        suppressor.strength = clamped.clickSuppression
        denoiser.strength = clamped.noiseReduction

        if clamped.highPassHz != appliedHighPassHz {
            highPass.configure(kind: .highpass, frequency: clamped.highPassHz, q: 0.707)
            appliedHighPassHz = clamped.highPassHz
        }

        shifter.formantRatio = clamped.formantRatio
        breath.amount = clamped.breathiness
        highShaper.formantRatio = clamped.formantRatio
        // Only while the shifter is actually shifting. With the effect off, or
        // a preset at unity, the shifter passes the voice through untouched and
        // there is nothing to repair — replacing the top of a real voice with
        // synthetic noise for no reason is a strange thing for a bypass to do.
        highShaper.mix = isShifting(clamped) ? clamped.highBandResynthesis : 0
        formantCorrector.ratio = clamped.formantRatio
        formantCorrector.amount = clamped.formantCorrection
        // With a target set, the ratio is worked out per block from what the
        // speaker is actually doing; without one it is the parameter itself.
        if clamped.targetPitchHz <= 0 {
            shifter.pitchRatio = clamped.pitchRatio
        }

        eq.setBands(clamped.eqBands)

        drive.amount = clamped.driveAmount
        drive.bitDepth = clamped.driveBitDepth
        drive.downsampleHz = clamped.driveDownsampleHz
        drive.mix = clamped.driveMix

        reverb.roomSize = clamped.reverbRoomSize
        reverb.damping = clamped.reverbDamping
        reverb.mix = clamped.reverbMix
    }

    /// Follows the speaker's own pitch, slowly, and aims the shifter so the
    /// result lands on the target.
    ///
    /// Deliberately slow. Following the pitch closely would flatten every
    /// sentence into a monotone, because holding the output at one frequency
    /// means undoing exactly the intonation that makes speech sound alive.
    /// What is wanted is the speaker's resting pitch — a property of the person
    /// that takes seconds to establish and then barely moves — with all of
    /// their expression left riding on top of it.
    private func updatePitchRatioForTarget(voiced: Bool, frameCount: Int) {
        let target = parameters.targetPitchHz
        guard target > 0 else { return }
        guard voiced, tracker.periodSamples > 0 else { return }

        let heard = sampleRate / tracker.periodSamples
        guard heard > 50, heard < 500 else { return }

        // Octave errors are ignored rather than averaged in: a tracker that
        // slips an octave for one frame would otherwise drag the whole
        // estimate with it. But the gate cannot be absolute, because the first
        // frame seeds it — one octave-halved estimate at the wrong moment would
        // otherwise lock the target an octave out for the rest of the session,
        // with nothing the user could do about it. Persistent disagreement wins.
        if speakerPitchHz > 0, heard < speakerPitchHz * 0.6 || heard > speakerPitchHz * 1.7 {
            disagreeingFrames += 1
            if disagreeingFrames < 60 { return }
            speakerPitchHz = 0
            disagreeingFrames = 0
        } else {
            disagreeingFrames = 0
        }

        if speakerPitchHz == 0 {
            speakerPitchHz = heard
            voicedSeconds = 0
            return
        }

        let elapsed = Float(frameCount) / sampleRate
        voicedSeconds += elapsed

        // Quick while it is still learning who is speaking, then very slow.
        // The slow constant is the important one: a sentence rises and falls
        // over a second or two, and an estimate that followed that would cancel
        // the intonation out — the output would sit on one note and sound like
        // a machine reading. Over half a minute, only the speaker changes.
        let timeConstant: Float = voicedSeconds < 2 ? 0.4 : 30
        speakerPitchHz += (heard - speakerPitchHz) * min(elapsed / timeConstant, 1)

        shifter.pitchRatio = min(max(target / speakerPitchHz, 0.5), 2)
    }

    /// The speaker's resting pitch, learned while they talk.
    private var speakerPitchHz: Float = 0
    private var voicedSeconds: Float = 0
    private var disagreeingFrames = 0

    /// What the shifter is currently being asked to do, for the interface to
    /// show — with a target set it is not the number in the preset.
    public var effectivePitchRatio: Float { shifter.pitchRatio }
    public var detectedPitchHz: Float { speakerPitchHz }

    private func isShifting(_ parameters: VoiceParameters) -> Bool {
        if parameters.targetPitchHz > 0 { return true }
        return abs(parameters.pitchRatio - 1) > 0.001 || abs(parameters.formantRatio - 1) > 0.001
    }

    public func reset() {
        tracker.reset()
        samplesSinceAnalysis = 0
        suppressor.reset()
        denoiser.reset()
        splitFilters.forEach { $0.reset() }
        highShaper.reset()
        breath.reset()
        formantCorrector.reset()
        speakerPitchHz = 0
        voicedSeconds = 0
        disagreeingFrames = 0
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

        // Analysed before anything has been done to it: a gate that has
        // already closed, or a click that has already been ducked, would make
        // the tracker answer a question about audio nobody is going to hear.
        tracker.push(buffer, frameCount: frameCount)
        samplesSinceAnalysis += frameCount
        while samplesSinceAnalysis >= analysisHop {
            samplesSinceAnalysis -= analysisHop
            tracker.analyse()
        }
        let voiced = tracker.isVoiced
        suppressor.isVoiced = voiced
        gate.isVoiced = voiced
        breath.isVoiced = voiced
        denoiser.isVoiced = voiced
        highShaper.isVoiced = voiced
        updatePitchRatioForTarget(voiced: voiced, frameCount: frameCount)

        // Clicks first: a key press is loud enough to hold a gate open, and
        // removing it before the gate decides anything keeps the two from
        // arguing.
        suppressor.process(buffer, frameCount: frameCount)
        // Steady noise next, before the gate: with the room tone already taken
        // out, the gate has a much clearer difference between speech and
        // silence to work with, and can sit at a gentler threshold.
        denoiser.process(buffer, frameCount: frameCount)
        gate.process(buffer, frameCount: frameCount)
        highPass.process(buffer, frameCount: frameCount)
        // Harmonics one way, air the other. Below the split the voice is
        // periodic and the shifter's repetition is exactly right; above it the
        // signal is breath and hiss, and repeating that is what makes a shifted
        // voice buzz.
        lowScratch.withUnsafeMutableBufferPointer { low in
            highScratch.withUnsafeMutableBufferPointer { high in
                guard let lowBase = low.baseAddress, let highBase = high.baseAddress else { return }

                // Chunked rather than truncated. A block longer than the
                // scratch buffers has to come out the far end whole: dropping
                // its tail would leave that audio unprocessed and put the
                // shifter's timeline permanently out of step with the input.
                var offset = 0
                while offset < frameCount {
                    let frames = min(frameCount - offset, VoiceChain.maximumBlock)
                    let block = buffer + offset

                    for i in 0..<frames { lowBase[i] = block[i] }
                    splitFilters.forEach { $0.process(lowBase, frameCount: frames) }
                    // Telescoping, so the two halves add back to the input exactly.
                    for i in 0..<frames { highBase[i] = block[i] - lowBase[i] }

                    shifter.process(lowBase, frameCount: frames)
                    highShaper.process(highBase, frameCount: frames)

                    for i in 0..<frames { block[i] = lowBase[i] + highBase[i] }
                    offset += frames
                }
            }
        }
        // Straight after the shifter, where the uniform scaling it applied is
        // still the only thing shaping the formants.
        formantCorrector.process(buffer, frameCount: frameCount)
        breath.process(buffer, frameCount: frameCount)
        eq.process(buffer, frameCount: frameCount)
        drive.process(buffer, frameCount: frameCount)
        reverb.process(buffer, frameCount: frameCount)

        if outputGain != 1 {
            for i in 0..<frameCount { buffer[i] *= outputGain }
        }
    }
}
