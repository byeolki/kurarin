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
    /// Output fundamental relative to input. 2 is an octave up.
    public var pitchRatio: Float = 1 {
        didSet { pitchRatio = min(max(pitchRatio, 0.5), 2) }
    }

    /// Spectral envelope scaling. Above 1 shrinks the apparent vocal tract.
    public var formantRatio: Float = 1 {
        didSet { formantRatio = min(max(formantRatio, 0.5), 2) }
    }

    public let sampleRate: Float
    public let latencyMode: LatencyMode

    /// Delay this unit adds, in frames. Fixed for the lifetime of the instance:
    /// changing it mid-stream would drop or repeat audio, so the owner
    /// rebuilds the shifter when the user picks a different mode.
    public let latencyFrames: Int

    private static let maximumFormantRatio: Float = 2

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
    private let tracker: PitchTracker

    private static let windowTableSize = 4096
    private let windowTable: [Float]

    public init(sampleRate: Float, latencyMode: LatencyMode) {
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
        latencyFrames = Int((maximumPeriod * (1 + VoiceShifter.maximumFormantRatio)).rounded(.up))

        var size = 1
        while size < (latencyFrames * 4 + 8192) { size <<= 1 }
        inputRing = [Float](repeating: 0, count: size)
        outputRing = [Float](repeating: 0, count: size)
        ringMask = size - 1

        tracker = PitchTracker(sampleRate: sampleRate, minimumHz: latencyMode.minimumPitchHz)

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
        tracker.reset()
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

        tracker.push(buffer, frameCount: frameCount)
        samplesSinceAnalysis += frameCount
        while samplesSinceAnalysis >= analysisHop {
            samplesSinceAnalysis -= analysisHop
            tracker.analyse()
        }
    }

    private func generateGrains() {
        let formant = min(max(formantRatio, 0.5), VoiceShifter.maximumFormantRatio)
        let pitch = min(max(pitchRatio, 0.5), 2)

        while true {
            let voiced = tracker.isVoiced && tracker.periodSamples > 0
            let period = voiced
                ? min(max(tracker.periodSamples, minimumPeriod), maximumPeriod)
                : unvoicedGrain
            let advance = voiced ? Double(period / pitch) : Double(period)

            // Follow the synthesis timeline with the analysis marks. When the
            // synthesis spacing is shorter than a period the same analysis mark
            // serves several grains, which is exactly how PSOLA raises pitch
            // without stretching time.
            while analysisPosition + Double(period) < synthesisPosition {
                analysisPosition += Double(period)
                if voiced {
                    let target = refineToGlottalPulse(near: analysisPosition, period: period)
                    // Ease towards the detected pulse instead of jumping onto
                    // it. Snapping outright reintroduces the very jitter the
                    // refinement exists to remove, because the peak estimate
                    // carries its own small error that tracks the fractional
                    // part of the period. A partial correction still bounds the
                    // drift but leaves no periodic residue to modulate the
                    // output.
                    analysisPosition += (target - analysisPosition) * 0.25
                }
            }
            if analysisPosition > synthesisPosition {
                analysisPosition = synthesisPosition
            }

            let readReach = analysisPosition + Double(period * formant) + 2
            if readReach >= Double(inputWritten) { break }

            layDown(period: period, formant: formant, advance: Float(advance))
            synthesisPosition += advance
        }
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

    private func layDown(period: Float, formant: Float, advance: Float) {
        let halfOutput = Int(period)
        guard halfOutput > 1 else { return }

        // Hann windows of length 2P laid down every S samples sum to P/S, so
        // the reciprocal keeps the level independent of the shift ratio.
        let gain = advance / period
        let synthesisCentre = Int(synthesisPosition.rounded())
        // Periods are rarely a whole number of samples, so the ideal mark falls
        // between two of them. Rounding the placement alone leaves a sub-sample
        // jitter that repeats with the fractional part and shows up as a low
        // buzz under the voice. Folding the remainder into the read position
        // moves the correction into the interpolator, where it costs nothing.
        let fractional = Float(synthesisPosition - Double(synthesisCentre))
        let windowScale = Float(VoiceShifter.windowTableSize - 1) / Float(2 * halfOutput)

        inputRing.withUnsafeBufferPointer { input in
            outputRing.withUnsafeMutableBufferPointer { output in
                guard let source = input.baseAddress, let destination = output.baseAddress else { return }

                for j in -halfOutput...halfOutput {
                    let outputIndex = synthesisCentre + j
                    if outputIndex < outputRead { continue }

                    let offsetFromCentre = Float(j) - fractional
                    let windowPosition = min(
                        max((offsetFromCentre + Float(halfOutput)) * windowScale, 0),
                        Float(VoiceShifter.windowTableSize - 1)
                    )
                    let windowIndex = Int(windowPosition)
                    let windowFraction = windowPosition - Float(windowIndex)
                    let w = windowIndex + 1 < VoiceShifter.windowTableSize
                        ? windowTable[windowIndex] + (windowTable[windowIndex + 1] - windowTable[windowIndex]) * windowFraction
                        : windowTable[VoiceShifter.windowTableSize - 1]

                    let sourcePosition = analysisPosition + Double(offsetFromCentre) * Double(formant)
                    let sample = interpolate(source, at: sourcePosition)

                    destination[outputIndex & ringMask] += sample * w * gain
                }
            }
        }
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
}
