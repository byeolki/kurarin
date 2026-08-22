import Foundation

/// Pitch and formant shifter built on time-domain PSOLA.
///
/// Pitch and formant are separate controls. Moving pitch alone turns a voice
/// into a chipmunk because the resonances of the vocal tract move with it; a
/// convincing child or giant needs the resonances moved by a different amount
/// than the fundamental, or not at all.
///
/// Two mechanisms, each owning one axis:
///
/// - **Pitch** comes from the spacing of the synthesis marks. Grains are laid
///   down every `period / pitchRatio` samples, so the output repeats at a rate
///   the caller chooses regardless of the input rate.
/// - **Formants** come from resampling each grain before it is laid down.
///   Reading the source with a step of `formantRatio` scales the whole spectrum,
///   and since the grain is only a couple of periods long, what survives that
///   scaling is the spectral envelope — the formants — while the periodicity is
///   re-imposed by the mark spacing.
///
/// Unvoiced sounds take a different path. PSOLA slices on glottal periods, and
/// a fricative has none, so slicing it on invented marks produces a buzzing
/// artefact where an "s" should be. Those frames instead get fixed-length
/// grains laid down at their original spacing, resampled by the formant ratio
/// only: noise has no pitch to move, and what the ear reads as "smaller" or
/// "bigger" in a fricative is entirely spectral position.
///
/// (The design sketch called for a phase vocoder on the unvoiced path. Fixed
/// grain overlap-add replaced it: on noise the two are perceptually equivalent,
/// while overlap-add keeps transients intact and costs no extra latency.)
public final class VoiceShifter: AudioProcessor {
    /// Bounds on both ratios.
    ///
    /// The maximum is not a free choice: `latencyFrames` is sized from it,
    /// because a grain read stretched by the formant ratio reaches that much
    /// further into the input than the mark it is centred on. Raising it here
    /// without rebuilding the delay budget would have the shifter read audio
    /// that has not arrived.
    public static let minimumRatio: Float = 0.5
    public static let maximumRatio: Float = 2

    private static func bounded(_ ratio: Float) -> Float {
        min(max(ratio, minimumRatio), maximumRatio)
    }

    /// Output fundamental relative to input. 2 is an octave up.
    public var pitchRatio: Float = 1 {
        didSet { pitchRatio = VoiceShifter.bounded(pitchRatio) }
    }

    /// Spectral envelope scaling. Above 1 shrinks the apparent vocal tract.
    public var formantRatio: Float = 1 {
        didSet { formantRatio = VoiceShifter.bounded(formantRatio) }
    }

    public let sampleRate: Float
    public let latencyMode: LatencyMode

    /// Delay this unit adds, in frames. Fixed for the lifetime of the instance:
    /// changing it mid-stream would drop or repeat audio, so the owner
    /// rebuilds the shifter when the user picks a different mode.
    public let latencyFrames: Int

    private let minimumPeriod: Float
    private let maximumPeriod: Float
    private let unvoicedGrain: Float
    private let analysisHop: Int

    private let ringMask: Int
    private var inputRing: [Float]
    private var outputRing: [Float]

    /// Absolute sample counts. Doubles rather than floats because a float loses
    /// integer precision after about six minutes at 48 kHz.
    private var inputWritten: Int = 0
    private var outputRead: Int = 0
    private var synthesisPosition: Double = 0
    private var analysisPosition: Double = 0

    private var samplesSinceAnalysis: Int = 0
    /// How many grains have been laid down from the current analysis mark. A
    /// raised pitch needs more output grains than there are input periods, so
    /// beyond the first the same audio is being repeated.
    private var reuseCount = 0
    private var random: UInt64 = 0x9E3779B97F4A7C15
    /// The voiced verdict after debouncing. The two paths through this unit
    /// sound different — one moves pitch, the other cannot — so flipping
    /// between them on a marginal frame is audible as a stutter in the middle
    /// of a word. A change has to be agreed on twice before it is acted on.
    private var stableVoiced = false
    private var disagreeingFrames = 0
    private let tracker: PitchTracker
    /// Whether this instance is responsible for feeding the tracker. When the
    /// chain owns it, the chain has already pushed this block before the
    /// shifter sees it.
    private let ownsTracker: Bool

    private static let windowTableSize = 4096
    private let windowTable: [Float]

    /// - Parameter tracker: the chain's shared pitch tracker, already fed with
    ///   this block's audio. Passing one in lets the gate and the click
    ///   suppressor act on the same voiced/unvoiced verdict the shifter uses,
    ///   rather than each unit running its own analysis over a slightly
    ///   different version of the signal. Left out, the shifter keeps its own
    ///   and feeds it, which is what the unit tests want.
    public init(sampleRate: Float, latencyMode: LatencyMode, tracker: PitchTracker? = nil) {
        self.sampleRate = sampleRate
        self.latencyMode = latencyMode

        maximumPeriod = sampleRate / latencyMode.minimumPitchHz
        minimumPeriod = sampleRate / 500
        unvoicedGrain = sampleRate * 0.006
        analysisHop = latencyMode.hopSize

        // A grain centred on the synthesis mark reaches one period forward in
        // the output, and reading it stretched by the formant ratio reaches
        // `period × ratio` forward in the input. Both have to be in hand before
        // a sample can be emitted.
        latencyFrames = Int((maximumPeriod * (1 + VoiceShifter.maximumRatio)).rounded(.up))

        var size = 1
        while size < (latencyFrames * 4 + 8192) { size <<= 1 }
        inputRing = [Float](repeating: 0, count: size)
        outputRing = [Float](repeating: 0, count: size)
        ringMask = size - 1

        if let tracker {
            self.tracker = tracker
            ownsTracker = false
        } else {
            self.tracker = PitchTracker(sampleRate: sampleRate, minimumHz: latencyMode.minimumPitchHz)
            ownsTracker = true
        }

        windowTable = (0..<VoiceShifter.windowTableSize).map { index in
            let phase = Float(index) / Float(VoiceShifter.windowTableSize - 1)
            return 0.5 - 0.5 * cosf(2 * .pi * phase)
        }

        // Pretend the ring already holds `latencyFrames` of silence so every
        // absolute position stays non-negative from the first block onward.
        inputWritten = latencyFrames
    }

    public func reset() {
        for i in inputRing.indices { inputRing[i] = 0 }
        for i in outputRing.indices { outputRing[i] = 0 }
        inputWritten = latencyFrames
        outputRead = 0
        synthesisPosition = 0
        analysisPosition = 0
        samplesSinceAnalysis = 0
        reuseCount = 0
        stableVoiced = false
        disagreeingFrames = 0
        if ownsTracker { tracker.reset() }
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Bypass cleanly when there is nothing to do, so a preset at unity does
        // not pay the latency or the artefacts of a round trip through PSOLA.
        if abs(pitchRatio - 1) < 0.001 && abs(formantRatio - 1) < 0.001 {
            passThrough(buffer, frameCount: frameCount)
            return
        }

        ingest(buffer, frameCount: frameCount)
        generateGrains()
        emit(buffer, frameCount: frameCount)
    }

    /// Keeps the delay line consistent while bypassed, so toggling an effect on
    /// or off does not jump the output forward by the latency.
    private func passThrough(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        ingest(buffer, frameCount: frameCount)
        for i in 0..<frameCount {
            let position = outputRead + i
            outputRing[position & ringMask] = 0
            buffer[i] = inputRing[position & ringMask]
        }
        outputRead += frameCount
        synthesisPosition = Double(outputRead + latencyFrames)
        analysisPosition = synthesisPosition
    }

    private func ingest(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount {
            inputRing[(inputWritten + i) & ringMask] = buffer[i]
        }
        inputWritten += frameCount

        updateVoicedState(frameCount: frameCount)

        guard ownsTracker else { return }
        tracker.push(buffer, frameCount: frameCount)
        samplesSinceAnalysis += frameCount
        while samplesSinceAnalysis >= analysisHop {
            samplesSinceAnalysis -= analysisHop
            tracker.analyse()
        }
    }

    /// - Parameter frameCount: how much audio this verdict covers. Counting
    ///   callbacks instead would make the debounce mean nothing at a sixty-four
    ///   frame buffer and eighty milliseconds at a two-thousand frame one — the
    ///   host chooses that number, not us.
    private func updateVoicedState(frameCount: Int) {
        let raw = tracker.isVoiced && tracker.periodSamples > 0
        if raw == stableVoiced {
            disagreeingFrames = 0
        } else {
            disagreeingFrames += frameCount
            if disagreeingFrames >= Int(0.012 * sampleRate) {
                stableVoiced = raw
                disagreeingFrames = 0
            }
        }
    }

    /// Lays down grains until the input runs out.
    ///
    /// One turn of the loop places one output grain: pick the period, walk the
    /// analysis marks up to the synthesis clock, check the audio it wants to
    /// read has arrived, and emit. The synthesis clock is what the caller
    /// controls through `pitchRatio`; everything else follows it.
    private func generateGrains() {
        // Both setters bound their property, so no clamp is needed here — but
        // hoisting them out of the loop keeps one grain from being laid down
        // with a ratio the next one does not share.
        let formant = formantRatio
        let pitch = pitchRatio

        while true {
            let voiced = stableVoiced
            let period = voiced
                ? min(max(tracker.periodSamples, minimumPeriod), maximumPeriod)
                : unvoicedGrain
            let advance = voiced ? Double(period / pitch) : Double(period)

            let advancedAnalysis = advanceAnalysisMarks(period: period, voiced: voiced)

            // Both ends of the grain have to be in hand: the mark itself, and
            // however far past it the formant ratio stretches the read.
            let readReach = analysisPosition + Double(period * formant) + 2
            if readReach >= Double(inputWritten) { break }

            reuseCount = advancedAnalysis ? 0 : reuseCount + 1
            let readOffset = voiced && reuseCount > 0
                ? decorrelatingReadOffset(period: period, formant: formant)
                : 0

            layDown(period: period, formant: formant, advance: Float(advance), readOffset: readOffset)

            // Real voices are not metronomes: consecutive glottal periods
            // differ by a fraction of a percent, and an output with none of
            // that variation is heard as synthetic however good the spectrum
            // is.
            //
            // Deliberately left untested. The effect is there and behaves as
            // jitter should — over a long lag it accumulates, so the output's
            // own autocorrelation peak falls from 0.9609 without it to 0.9566
            // with — but 0.4% is too thin a margin to hang a regression test
            // on; a threshold in that gap would fire on changes that have
            // nothing to do with it. The perceptual claim above is not
            // something these tests can reach either way.
            let jitter = 1 + (Double(nextRandom() % 1000) / 1000 - 0.5) * 0.006
            synthesisPosition += advance * jitter
        }
    }

    /// Walks the analysis marks forward until they have caught up with the
    /// synthesis clock, and reports whether any ground was covered.
    ///
    /// When the synthesis spacing is shorter than a period the marks do not
    /// move at all and the same analysis mark serves several grains, which is
    /// exactly how PSOLA raises pitch without stretching time. A `false` here
    /// is therefore not a failure — it is the caller's signal that the next
    /// grain repeats audio, and repetition is what needs decorrelating.
    private func advanceAnalysisMarks(period: Float, voiced: Bool) -> Bool {
        var advanced = false
        while analysisPosition + Double(period) < synthesisPosition {
            advanced = true
            analysisPosition += Double(period)
            if voiced {
                let target = refineToGlottalPulse(near: analysisPosition, period: period)
                // Ease towards the detected pulse instead of jumping onto it.
                // Snapping outright reintroduces the very jitter the refinement
                // exists to remove, because the peak estimate carries its own
                // small error that tracks the fractional part of the period. A
                // partial correction still bounds the drift but leaves no
                // periodic residue to modulate the output.
                analysisPosition += (target - analysisPosition) * 0.25
            }
        }
        if analysisPosition > synthesisPosition {
            analysisPosition = synthesisPosition
        }
        return advanced
    }

    /// Snaps a predicted mark onto the nearest glottal pulse.
    ///
    /// Advancing marks by the estimated period alone is not enough. The
    /// estimate is good to about a percent, and a percent of error compounds:
    /// after a few dozen grains the marks have slid off the pulses, the Hann
    /// window starts cutting the loudest part of each period, and the output
    /// loses level and gains a warble. Re-anchoring every mark to the local
    /// peak bounds the error instead of letting it accumulate.
    private func refineToGlottalPulse(near position: Double, period: Float) -> Double {
        let radius = Int(period * 0.25)
        guard radius > 0 else { return position }

        let centre = Int(position.rounded())
        // Only search where the input actually exists.
        guard centre - radius >= 0, centre + radius < inputWritten else { return position }

        var bestOffset = 0
        var bestMagnitude: Float = 0
        for offset in -radius...radius {
            let magnitude = abs(inputRing[(centre + offset) & ringMask])
            if magnitude > bestMagnitude {
                bestMagnitude = magnitude
                bestOffset = offset
            }
        }

        // Snapping to the nearest whole sample is not enough. True periods are
        // fractional, so a whole-sample mark lands up to half a sample off, and
        // that error repeats with the fractional part of the period — a
        // low-frequency warble under the voice, made worse by formant shifting
        // because reading the grain stretched magnifies any misalignment. A
        // parabola through the peak recovers the sub-sample position.
        let index = centre + bestOffset
        let before = abs(inputRing[(index - 1) & ringMask])
        let here = bestMagnitude
        let after = abs(inputRing[(index + 1) & ringMask])
        let denominator = 2 * (2 * here - before - after)
        var subSample: Float = 0
        if abs(denominator) > 1e-12 {
            subSample = min(max((after - before) / denominator, -0.5), 0.5)
        }

        return Double(index) + Double(subSample)
    }

    /// How far back to read a grain that repeats audio already used.
    ///
    /// Reading the same audio again is what makes a shifted voice sound
    /// shifted. The harmonics survive repetition — they are periodic, so one
    /// period back is the same waveform — but the breath and the fricative
    /// noise riding on top of them are not, and repeating those turns aperiodic
    /// noise into a buzz locked to the new pitch. Measured on a breathy vowel
    /// raised by half: the noise above three kilohertz went from a periodicity
    /// of 0.01 to 0.27, sitting exactly on the new fundamental.
    ///
    /// So a repeat is read from a different glottal period instead: whole
    /// periods back, which leaves the harmonic content aligned and gives the
    /// noise a fresh sample of itself. Returns zero when there is not enough
    /// history to reach that far.
    private func decorrelatingReadOffset(period: Float, formant: Float) -> Double {
        // Bounded in time rather than in periods. Further back decorrelates the
        // noise better, but it is also older audio, and past thirty-odd
        // milliseconds the mouth has moved on — borrowing from there smears one
        // sound into the next. A deep voice gets fewer choices, which is the
        // right answer anyway: its periods are long enough that even one is a
        // different slice of noise.
        let maximumBack = max(1, min(8, Int(0.035 * sampleRate / period)))
        let candidate = Double(period) * Double(1 + Int(nextRandom()) % maximumBack)
        let earliestRead = analysisPosition - candidate - Double(period) * Double(formant) - 2
        guard earliestRead > 0 else { return 0 }
        return -candidate
    }

    /// Windows one grain out of the input and accumulates it into the output
    /// ring at the current synthesis mark.
    private func layDown(period: Float, formant: Float, advance: Float, readOffset: Double) {
        let halfOutput = Int(period)
        guard halfOutput > 1 else { return }

        // Hann windows of length 2P laid down every S samples sum to P/S, so
        // the reciprocal keeps the level independent of the shift ratio.
        let gain = advance / period
        let synthesisCentre = Int(synthesisPosition.rounded())
        // Periods are rarely a whole number of samples, so the ideal mark falls
        // between two of them. Rounding the placement alone leaves a sub-sample
        // error that repeats with the fractional part. Folding the remainder
        // into the read position moves the correction into the interpolator,
        // where it costs nothing.
        //
        // This is kept for being free and strictly more correct, not for a
        // measured gain. It used to claim the rounding showed up as a low buzz
        // under the voice; removing the correction changes every sample, but
        // level, envelope variation and energy below 80 Hz all come back
        // identical to five significant figures, so whatever it is worth is
        // below what these measurements can see.
        let fractional = Float(synthesisPosition - Double(synthesisCentre))
        // Hoisted: a divide per sample is not worth paying inside the loop.
        let windowScale = Float(VoiceShifter.windowTableSize - 1) / Float(2 * halfOutput)

        inputRing.withUnsafeBufferPointer { input in
            outputRing.withUnsafeMutableBufferPointer { output in
                guard let source = input.baseAddress, let destination = output.baseAddress else { return }

                for grainSample in -halfOutput...halfOutput {
                    let outputIndex = synthesisCentre + grainSample
                    if outputIndex < outputRead { continue }

                    let offsetFromCentre = Float(grainSample) - fractional
                    let windowPosition = min(
                        max((offsetFromCentre + Float(halfOutput)) * windowScale, 0),
                        Float(VoiceShifter.windowTableSize - 1)
                    )
                    let weight = windowValue(at: windowPosition)

                    let sourcePosition = analysisPosition + readOffset
                        + Double(offsetFromCentre) * Double(formant)
                    let sample = interpolate(source, at: sourcePosition)

                    destination[outputIndex & ringMask] += sample * weight * gain
                }
            }
        }
    }

    /// Reads the shared Hann table at a fractional position, which the caller
    /// has already scaled and bounded to the table.
    private func windowValue(at position: Float) -> Float {
        let index = Int(position)
        guard index + 1 < VoiceShifter.windowTableSize else {
            return windowTable[VoiceShifter.windowTableSize - 1]
        }
        let fraction = position - Float(index)
        return windowTable[index] + (windowTable[index + 1] - windowTable[index]) * fraction
    }

    /// Catmull-Rom interpolation. Linear interpolation acts as a lowpass that
    /// varies with the fractional offset, which on a formant-shifted grain
    /// reads as a dull, unstable top end.
    private func interpolate(_ ring: UnsafePointer<Float>, at position: Double) -> Float {
        let base = Int(position.rounded(.down))
        let t = Float(position - Double(base))

        let y0 = ring[(base - 1) & ringMask]
        let y1 = ring[base & ringMask]
        let y2 = ring[(base + 1) & ringMask]
        let y3 = ring[(base + 2) & ringMask]

        let a0 = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3
        let a1 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let a2 = -0.5 * y0 + 0.5 * y2

        return ((a0 * t + a1) * t + a2) * t + y1
    }

    private func emit(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount {
            let index = (outputRead + i) & ringMask
            buffer[i] = outputRing[index]
            // Clear behind the read pointer so the slot is empty the next time
            // a grain accumulates into it.
            outputRing[index] = 0
        }
        outputRead += frameCount
    }

    private func nextRandom() -> UInt64 {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        return random >> 33
    }
}
