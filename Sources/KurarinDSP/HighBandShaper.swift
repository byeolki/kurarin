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

    /// One bank to find out how loud each slice of the air is, one to put the
    /// noise back in the slices the formant ratio moved them to.
    private let analysisBank: Filterbank
    private let synthesisBank: Filterbank
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
    private var output: [Float]

    public init(sampleRate: Float, delayFrames: Int) {
        self.sampleRate = sampleRate
        self.delayFrames = max(1, delayFrames)

        let bandCount = HighBandShaper.edges.count + 1
        analysisBank = Filterbank(
            sampleRate: sampleRate,
            edges: HighBandShaper.edges,
            floor: HighBandShaper.splitHz,
            capacity: HighBandShaper.chunk
        )
        synthesisBank = Filterbank(
            sampleRate: sampleRate,
            edges: HighBandShaper.edges,
            floor: HighBandShaper.splitHz,
            capacity: HighBandShaper.chunk
        )

        analysisEnvelopes = [Float](repeating: 0, count: bandCount)
        synthesisEnvelopes = [Float](repeating: 0, count: bandCount)

        delayLine = [Float](repeating: 0, count: self.delayFrames)
        delayed = [Float](repeating: 0, count: HighBandShaper.chunk)
        noise = [Float](repeating: 0, count: HighBandShaper.chunk)
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
        let moved = HighBandShaper.edges.map {
            min(max($0 * formantRatio, base * 1.2), nyquist)
        }
        synthesisBank.setEdges(moved, floor: base)
    }

    public func reset() {
        analysisBank.reset()
        synthesisBank.reset()
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
        delayed.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            analysisBank.measure(base, frameCount: count) { index, level, frames in
                var envelope = self.analysisEnvelopes[index]
                envelope += (level - envelope) * self.smoothing(frames: frames)
                self.analysisEnvelopes[index] = withoutDenormals(envelope)
            }
        }
    }

    /// Fresh noise, one block of it.
    private func buildNoise(count: Int) {
        for i in 0..<count {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = Float(Int32(truncatingIfNeeded: random >> 32)) / Float(Int32.max)
        }
    }

    /// Shapes the noise into the moved bands, each carrying the level the
    /// original had in the band it came from.
    private func synthesise(count: Int) {
        for i in 0..<count { output[i] = noise[i] }
        output.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            synthesisBank.process(base, frameCount: count) { index, level, frames in
                var envelope = self.synthesisEnvelopes[index]
                envelope += (level - envelope) * self.smoothing(frames: frames)
                self.synthesisEnvelopes[index] = withoutDenormals(envelope)

                // Envelope matched to envelope rather than a fixed gain: noise
                // through a filter comes out at a level that depends on the
                // filter's width, and the widths move with the formant ratio.
                return min(self.analysisEnvelopes[index] / max(envelope, 1e-7), 40)
            }
        }
    }

    /// Slow enough to average across a glottal period. A voiced band arrives in
    /// bursts, so the chunk-to-chunk mean square swings widely, and a follower
    /// that chased it would settle near the peak of the swing rather than its
    /// average — which is the crest-factor mistake one level up.
    ///
    /// In seconds, not in callbacks: at sixty-four frames a fixed per-callback
    /// coefficient works out to about one glottal period, which is exactly the
    /// swing it is supposed to be averaging over.
    private func smoothing(frames: Int) -> Float {
        1 - expf(-(Float(frames) / sampleRate) / 0.045)
    }

}
