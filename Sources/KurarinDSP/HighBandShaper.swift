import Foundation

/// Rebuilds the top of the spectrum as noise instead of letting the pitch
/// shifter repeat it.
///
/// Speech divides in two. Below about five kilohertz it is harmonic — glottal
/// pulses, periodic, exactly what PSOLA is good at. Above that it is mostly
/// air: breath, and the hiss of "s" and "sh". PSOLA raises pitch by laying the
/// same glottal period down more often, and repeating a period repeats the
/// noise inside it, which turns air into a buzz locked to the new fundamental.
/// Measured on a breathy vowel raised by half, the noise above three kilohertz
/// went from a periodicity of 0.01 to 0.27. Reading repeats from earlier
/// periods brought that to 0.10; not repeating it at all is the rest of the
/// answer, and it is what the harmonic-plus-noise models in the literature do.
///
/// So the band is measured rather than moved: a handful of envelopes, one per
/// sub-band, taken from the original and used to shape fresh noise. Nothing is
/// repeated, so nothing can buzz.
///
/// The sub-bands are also where the shifter's size change reaches the noise.
/// A smaller speaker has shorter cavities and their resonances sit higher, so
/// the synthesis bands are the analysis bands moved by the formant ratio — the
/// reason a child's "s" is higher than an adult's, which pitch alone will never
/// produce.
public final class HighBandShaper: AudioProcessor {
    /// Where the harmonics stop and the air begins. Deliberately high: below
    /// this a voice still has harmonics worth keeping, and replacing them with
    /// noise sounds like whispering.
    public static let splitHz: Float = 5000

    /// 0 leaves the original band alone, 1 replaces it entirely.
    public var mix: Float = 1
    /// Whether the shifter is currently repeating glottal periods.
    ///
    /// Only voiced audio is repeated, and only repetition creates the buzz
    /// this unit exists to prevent. A fricative goes through the shifter's
    /// unvoiced path, which does not repeat anything, so rebuilding it as
    /// synthetic noise replaces a real sound with an approximation of it for
    /// no benefit — and an "s" is mostly this band, so the approximation is
    /// what the listener hears.
    public var isVoiced: Bool = false
    public var formantRatio: Float = 1 {
        didSet {
            if abs(formantRatio - configuredRatio) > 0.01 { configureSynthesis() }
        }
    }

    /// Matches the shifter, so the rebuilt band lines up with the band it
    /// belongs to.
    public let delayFrames: Int

    private let sampleRate: Float
    /// Band edges above the split. Four is enough to place the energy of a
    /// fricative; more would track the spectrum more closely and cost more than
    /// the difference is worth.
    private static let edges: [Float] = [7000, 9500, 13000]

    private let analysisFilters: [[Biquad]]
    private let synthesisFilters: [[Biquad]]
    /// The generated noise starts as white, which is to say it has as much
    /// energy at fifty hertz as at ten kilohertz. The telescoping split below
    /// assumes its source already begins at the split, so without this the
    /// lowest synthesis band reaches down to DC and lays broadband rumble under
    /// the voice — measured at fifty decibels above the input below two hundred
    /// hertz, rising and falling with every sibilant.
    private let noiseHighPass: [Biquad]
    /// The same treatment for the signal being measured.
    ///
    /// The chain hands over `original - lowpass(split)`, which is not the same
    /// as "everything above the split": a crossover has a slope, so a loud
    /// vowel leaves a residue below it that is small in absolute terms and
    /// enormous compared to the air up here. The telescoping split has no lower
    /// bound of its own, so that residue lands in the first sub-band, and its
    /// level — which follows the vowel — comes back out as noise. That is the
    /// hiss that grows with the voice.
    ///
    /// Applied to the copy being analysed, never to the signal being passed
    /// through: with the rebuild mixed out this unit is a plain delay, and it
    /// has to stay one.
    private let analysisHighPass: [Biquad]
    private var analysisScratch: [Float]
    private var configuredRatio: Float = 1

    private var delayLine: [Float]
    private var delayIndex = 0
    private var voicedBlend: Float = 0

    private var analysisEnvelopes: [Float]
    private var synthesisEnvelopes: [Float]
    private var random: UInt64 = 0x853C49E6748FEA9B

    private static let chunk = 512
    private var delayed: [Float]
    private var noise: [Float]
    private var previousLow: [Float]
    private var currentLow: [Float]
    private var bandBuffer: [Float]
    private var output: [Float]

    public init(sampleRate: Float, delayFrames: Int) {
        self.sampleRate = sampleRate
        self.delayFrames = max(1, delayFrames)

        let bandCount = HighBandShaper.edges.count + 1
        analysisFilters = HighBandShaper.edges.map { frequency in
            (0..<2).map { _ in
                let filter = Biquad(sampleRate: sampleRate)
                filter.configure(kind: .lowpass, frequency: frequency, q: 0.707)
                return filter
            }
        }
        synthesisFilters = HighBandShaper.edges.map { _ in
            (0..<2).map { _ in Biquad(sampleRate: sampleRate) }
        }
        noiseHighPass = (0..<2).map { _ in Biquad(sampleRate: sampleRate) }
        analysisHighPass = (0..<2).map { _ in
            let filter = Biquad(sampleRate: sampleRate)
            filter.configure(kind: .highpass, frequency: HighBandShaper.splitHz, q: 0.707)
            return filter
        }
        analysisScratch = [Float](repeating: 0, count: HighBandShaper.chunk)

        analysisEnvelopes = [Float](repeating: 0, count: bandCount)
        synthesisEnvelopes = [Float](repeating: 0, count: bandCount)

        delayLine = [Float](repeating: 0, count: self.delayFrames)
        delayed = [Float](repeating: 0, count: HighBandShaper.chunk)
        noise = [Float](repeating: 0, count: HighBandShaper.chunk)
        previousLow = [Float](repeating: 0, count: HighBandShaper.chunk)
        currentLow = [Float](repeating: 0, count: HighBandShaper.chunk)
        bandBuffer = [Float](repeating: 0, count: HighBandShaper.chunk)
        output = [Float](repeating: 0, count: HighBandShaper.chunk)

        configureSynthesis()
    }

    private func configureSynthesis() {
        configuredRatio = formantRatio
        let nyquist = sampleRate * 0.45

        // The floor of the rebuilt band moves with the ratio too. Holding it at
        // the split while the edges above it come down would collapse the lowest
        // sub-bands into nothing and quietly drop the five-to-seven kilohertz
        // air out of a deepened voice.
        let base = min(max(HighBandShaper.splitHz * formantRatio, 2500), nyquist * 0.9)
        noiseHighPass.forEach { $0.configure(kind: .highpass, frequency: base, q: 0.707) }

        for (index, edge) in HighBandShaper.edges.enumerated() {
            let moved = min(max(edge * formantRatio, base * 1.2), nyquist)
            synthesisFilters[index].forEach {
                $0.configure(kind: .lowpass, frequency: moved, q: 0.707)
            }
        }
    }

    public func reset() {
        analysisFilters.forEach { $0.forEach { $0.reset() } }
        synthesisFilters.forEach { $0.forEach { $0.reset() } }
        noiseHighPass.forEach { $0.reset() }
        analysisHighPass.forEach { $0.reset() }
        for i in delayLine.indices { delayLine[i] = 0 }
        delayIndex = 0
        voicedBlend = 0
        for i in analysisEnvelopes.indices {
            analysisEnvelopes[i] = 0
            synthesisEnvelopes[i] = 0
        }
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let count = min(frameCount - offset, HighBandShaper.chunk)
            processChunk(buffer + offset, count: count)
            offset += count
        }
    }

    private func processChunk(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        // The band arrives before the shifter has finished with the rest of the
        // voice, so it waits here for as long as the shifter takes.
        for i in 0..<count {
            delayed[i] = delayLine[delayIndex]
            delayLine[delayIndex] = buffer[i]
            delayIndex = (delayIndex + 1) % delayLine.count
        }

        // Crossfaded rather than switched: voicing is decided per block, and
        // stepping between the real band and the rebuilt one at a block
        // boundary is a click.
        let target: Float = isVoiced ? 1 : 0
        voicedBlend += (target - voicedBlend) * 0.25
        let blend = min(max(mix, 0), 1) * voicedBlend
        // The envelopes and the filters are kept current even when the rebuilt
        // band is not being used, so that turning it up resumes from what the
        // voice is doing now rather than from wherever it was left.
        measureAnalysisEnvelopes(count: count)
        guard blend > 0.001 else {
            for i in 0..<count { buffer[i] = delayed[i] }
            return
        }

        buildNoise(count: count)
        synthesise(count: count)

        for i in 0..<count {
            buffer[i] = delayed[i] * (1 - blend) + output[i] * blend
        }
    }

    /// What the original band is doing, per sub-band.
    private func measureAnalysisEnvelopes(count: Int) {
        for i in 0..<count { analysisScratch[i] = delayed[i] }
        analysisScratch.withUnsafeMutableBufferPointer { base in
            guard let pointer = base.baseAddress else { return }
            analysisHighPass.forEach { $0.process(pointer, frameCount: count) }
        }
        splitAndTrack(source: .analysis, filters: analysisFilters, count: count, collect: false)
    }

    /// Fresh noise, one block of it.
    private func buildNoise(count: Int) {
        for i in 0..<count {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = Float(Int32(truncatingIfNeeded: random >> 32)) / Float(Int32.max)
        }
        noise.withUnsafeMutableBufferPointer { base in
            guard let pointer = base.baseAddress else { return }
            noiseHighPass.forEach { $0.process(pointer, frameCount: count) }
        }
    }

    /// Shapes the noise into the moved bands, each carrying the level the
    /// original had in the band it came from.
    private func synthesise(count: Int) {
        for i in 0..<count { output[i] = 0 }
        splitAndTrack(source: .noise, filters: synthesisFilters, count: count, collect: true)
    }

    private enum Source { case analysis, noise }

    /// Splits a block into sub-bands with the telescoping lowpass trick and
    /// tracks each band's envelope; when collecting, the shaped band is added
    /// to the output as it goes.
    ///
    /// Written against the stored buffers directly rather than taking them as
    /// parameters: handing one of this object's arrays to a method as `inout`
    /// while a closure inside reads another of its properties is an
    /// exclusivity violation, and Swift traps on it at run time rather than
    /// letting it slide.
    private func splitAndTrack(source: Source, filters: [[Biquad]], count: Int, collect: Bool) {
        for i in 0..<count { previousLow[i] = 0 }

        // Symmetric, and slow enough to average across a glottal period.
        //
        // Rising faster than it falls would repeat the crest-factor mistake one
        // level up: a voiced band arrives in bursts, so the block-to-block mean
        // square swings widely, and a follower that jumps to the loud blocks
        // and eases off the quiet ones settles near the peak of that swing
        // rather than its average. The rebuilt band then carries the energy of
        // the loudest moment continuously.
        let smoothing: Float = 0.12

        for index in 0...filters.count {
            if index < filters.count {
                for i in 0..<count {
                    currentLow[i] = source == .analysis ? analysisScratch[i] : noise[i]
                }
                currentLow.withUnsafeMutableBufferPointer { low in
                    guard let base = low.baseAddress else { return }
                    filters[index].forEach { $0.process(base, frameCount: count) }
                }
                for i in 0..<count { bandBuffer[i] = currentLow[i] - previousLow[i] }
            } else {
                // Everything above the last edge.
                for i in 0..<count {
                    let sample = source == .analysis ? analysisScratch[i] : noise[i]
                    bandBuffer[i] = sample - previousLow[i]
                }
            }

            // Root mean square, not a peak follower.
            //
            // The two signals being matched have completely different shapes.
            // A voiced band is a train of pulses with a high crest factor;
            // noise is not. Matching their peaks therefore matches the wrong
            // thing and lets the noise carry several times the energy of what
            // it replaced — measured at fourteen decibels of added hiss above
            // five kilohertz during speech, which is exactly what it sounded
            // like. Matching the mean square matches the loudness.
            var sum: Float = 0
            for i in 0..<count { sum += bandBuffer[i] * bandBuffer[i] }
            let blockRMS = count > 0 ? sqrtf(sum / Float(count)) : 0

            var envelope = source == .analysis ? analysisEnvelopes[index] : synthesisEnvelopes[index]
            // Still smoothed across blocks, so a fricative starting mid-block
            // does not step the level.
            envelope += (blockRMS - envelope) * smoothing
            envelope = withoutDenormals(envelope)
            if source == .analysis {
                analysisEnvelopes[index] = envelope
            } else {
                synthesisEnvelopes[index] = envelope
            }

            if collect {
                // Envelope matched to envelope rather than a fixed gain: noise
                // through a filter comes out at a level that depends on the
                // filter's width, and the widths move with the formant ratio.
                let gain = min(analysisEnvelopes[index] / max(envelope, 1e-7), 40)
                for i in 0..<count { output[i] += bandBuffer[i] * gain }
            }

            if index < filters.count {
                for i in 0..<count { previousLow[i] = currentLow[i] }
            }
        }
    }
}
