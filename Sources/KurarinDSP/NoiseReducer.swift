import Foundation

/// Removes steady background noise — a fan, a computer, air conditioning, the
/// hiss of a cheap preamp — the sound that is there the whole time and that a
/// gate can only cut between words.
///
/// The signal is split into bands, each band learns how quiet it gets, and
/// whatever sits at that level is treated as noise and turned down. A band the
/// voice is using stays open, so the reduction happens where the noise is
/// rather than across the whole spectrum.
///
/// **Why not a spectrum.** The usual approach is an FFT, a noise profile per
/// bin, and a subtraction. It measures more precisely and it costs two things
/// this cannot afford: a window of latency on a budget that is already
/// forty-odd milliseconds, and musical noise — isolated bins surviving the
/// subtraction and warbling like water — which is the sound people recognise
/// as "noise suppression". Wide bands do not have enough resolution to warble,
/// and IIR filters have no window to wait for.
///
/// **Why differences of lowpasses.** Bands are built as `LP(f2) - LP(f1)`
/// rather than as bandpass filters, because that sum telescopes: with every
/// band at unity the output is the input again, exactly, in magnitude and in
/// phase. A filterbank that cannot be turned off transparently is one nobody
/// can leave switched on.
public final class NoiseReducer: AudioProcessor {
    /// 0 is off. 1 removes as much as can be removed without the cure becoming
    /// more noticeable than the noise.
    public var strength: Float = 0
    /// Whether a voice is present, from the chain's shared tracker. Used to be
    /// more careful, never to stop reducing: noise does not pause when someone
    /// speaks.
    public var isVoiced: Bool = false

    /// Roughly logarithmic, spanning what a voice and its noise occupy. Eight
    /// bands is enough resolution to leave a vowel alone while removing the
    /// hiss above it, and few enough that no band can warble on its own.
    private static let crossovers: [Float] = [120, 300, 700, 1400, 2600, 4600, 8000]

    private let sampleRate: Float
    private let lowpasses: [[Biquad]]

    private var envelopes: [Float]
    private var noiseFloors: [Float]
    private var gains: [Float]
    private var warmUpCounts: [Int]

    private static let chunk = 512
    private var original: [Float]
    private var previousLow: [Float]
    private var currentLow: [Float]
    private var band: [Float]
    private var accumulator: [Float]

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate

        // Two sections per crossover: one biquad is too gentle a slope to keep
        // a loud band from leaking into a quiet neighbour and holding its noise
        // estimate up.
        lowpasses = NoiseReducer.crossovers.map { frequency in
            (0..<2).map { _ -> Biquad in
                let filter = Biquad(sampleRate: sampleRate)
                filter.configure(kind: .lowpass, frequency: frequency, q: 0.707)
                return filter
            }
        }

        let bandCount = NoiseReducer.crossovers.count + 1
        envelopes = [Float](repeating: 0, count: bandCount)
        noiseFloors = [Float](repeating: 0, count: bandCount)
        gains = [Float](repeating: 1, count: bandCount)
        warmUpCounts = [Int](repeating: 0, count: bandCount)

        original = [Float](repeating: 0, count: NoiseReducer.chunk)
        previousLow = [Float](repeating: 0, count: NoiseReducer.chunk)
        currentLow = [Float](repeating: 0, count: NoiseReducer.chunk)
        band = [Float](repeating: 0, count: NoiseReducer.chunk)
        accumulator = [Float](repeating: 0, count: NoiseReducer.chunk)
    }

    public func reset() {
        lowpasses.forEach { $0.forEach { $0.reset() } }
        for i in envelopes.indices {
            envelopes[i] = 0
            noiseFloors[i] = 0
            gains[i] = 1
            warmUpCounts[i] = 0
        }
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard strength > 0.001 else {
            // The filters still have to see the signal: switching on after a
            // silence would otherwise start from cold states and click.
            runFiltersOnly(buffer, frameCount: frameCount)
            return
        }

        var offset = 0
        while offset < frameCount {
            let count = min(frameCount - offset, NoiseReducer.chunk)
            processChunk(buffer + offset, count: count)
            offset += count
        }
    }

    private func processChunk(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            original[i] = buffer[i]
            previousLow[i] = 0
            accumulator[i] = 0
        }

        for (index, sections) in lowpasses.enumerated() {
            for i in 0..<count { currentLow[i] = original[i] }
            currentLow.withUnsafeMutableBufferPointer { low in
                guard let base = low.baseAddress else { return }
                sections.forEach { $0.process(base, frameCount: count) }
            }

            // The band between this crossover and the last.
            for i in 0..<count { band[i] = currentLow[i] - previousLow[i] }
            reduce(bandIndex: index, count: count)
            for i in 0..<count {
                accumulator[i] += band[i]
                previousLow[i] = currentLow[i]
            }
        }

        // Everything above the last crossover.
        for i in 0..<count { band[i] = original[i] - previousLow[i] }
        reduce(bandIndex: lowpasses.count, count: count)

        for i in 0..<count { buffer[i] = accumulator[i] + band[i] }
    }

    /// Learns one band's noise floor and turns down whatever is sitting on it.
    private func reduce(bandIndex: Int, count: Int) {
        let attack = coefficient(forMilliseconds: 5)
        let release = coefficient(forMilliseconds: 80)
        // The floor follows downwards in a fraction of a second and upwards
        // over many seconds. Asymmetry is the whole estimator: the quietest
        // thing a band has been recently is the noise in it, and anything that
        // rises is a signal until it has stayed up long enough to be the new
        // quiet.
        let floorDown = coefficient(forMilliseconds: 300)
        let floorUp = coefficient(forMilliseconds: 2000)
        // Until the floor has been anywhere, it simply is the envelope.
        // Starting it at zero and letting it climb would leave the estimate
        // wrong for as long as the climb took, which is exactly when a user
        // decides the feature does nothing.
        let warmUpSamples = Int(0.2 * sampleRate)

        // Over-subtraction: removing exactly the estimate leaves the noise
        // audibly present, because the estimate is an average and the noise
        // fluctuates around it. Removing rather more, and holding a floor under
        // the gain so nothing is ever silenced completely, is what keeps the
        // result sounding like a quieter room rather than a processed one.
        let over = 1.5 + 2 * strength * (isVoiced ? 0.6 : 1)
        var warmUp = warmUpCounts[bandIndex]
        let minimumGain = powf(10, -(5 + 15 * strength) / 20)

        var envelope = envelopes[bandIndex]
        var floor = noiseFloors[bandIndex]
        var gain = gains[bandIndex]

        band.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for i in 0..<count {
                let magnitude = abs(base[i])
                envelope = magnitude > envelope
                    ? envelope + (magnitude - envelope) * (1 - attack)
                    : envelope + (magnitude - envelope) * (1 - release)

                if warmUp < warmUpSamples && !isVoiced {
                    // Learning starts on the room, not on whoever is already
                    // talking. Until something has been learned the floor stays
                    // at zero, which means a gain of one: with no estimate, the
                    // safe thing to do is nothing.
                    warmUp += 1
                    floor = envelope
                } else if envelope < floor {
                    // Downwards is always safe: it can only make the reduction
                    // more cautious.
                    floor += (envelope - floor) * (1 - floorDown)
                } else if !isVoiced {
                    // Upwards only when nobody is speaking. An estimator that
                    // learns from whatever is steady eventually decides a held
                    // note is the room — which is precisely the failure everyone
                    // knows from noise suppression, where "aaah" fades out
                    // halfway through. Noise is steady and speech is not, but a
                    // sustained vowel is steady too, so steadiness cannot be the
                    // test. Periodicity can.
                    floor += (envelope - floor) * (1 - floorUp)
                }

                // Subtracted in power rather than in amplitude, which is what
                // keeps a voice intact. A band carrying speech ten times above
                // its noise loses a sixth of a decibel this way and a third of
                // its amplitude the other way — the difference between cleaning
                // a signal and thinning it.
                // Nothing is reduced until something has been learned. During
                // the warm-up the floor is simply the envelope, which would
                // otherwise read as "all of this is noise" and mute the first
                // fifth of a second of every session.
                let learning = warmUp < warmUpSamples
                let ratio = envelope > 0 ? floor / envelope : 1
                let remaining = 1 - over * ratio * ratio
                let target = learning
                    ? 1
                    : (remaining > 0 ? max(sqrtf(remaining), minimumGain) : minimumGain)
                // Smoothed in time so the band fades rather than steps, which
                // is the other half of not sounding processed.
                // Opening quickly and closing slowly, not the other way round.
                // The fast constant belongs to the direction that restores the
                // signal: a word starts in a couple of milliseconds, and a
                // reducer that takes eighty to get out of its way swallows the
                // start of every sentence. Closing can afford to be gradual —
                // nothing is waiting for the noise to come back.
                gain += (target - gain) * (target > gain ? (1 - attack) : (1 - release))

                base[i] *= gain
            }
        }

        warmUpCounts[bandIndex] = warmUp
        envelopes[bandIndex] = withoutDenormals(envelope)
        noiseFloors[bandIndex] = withoutDenormals(floor)
        gains[bandIndex] = withoutDenormals(gain)
    }

    /// Keeps the filter states current while the reducer is switched off.
    private func runFiltersOnly(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let count = min(frameCount - offset, NoiseReducer.chunk)
            for (index, sections) in lowpasses.enumerated() {
                for i in 0..<count { currentLow[i] = buffer[offset + i] }
                currentLow.withUnsafeMutableBufferPointer { low in
                    guard let base = low.baseAddress else { return }
                    sections.forEach { $0.process(base, frameCount: count) }
                }
            }
            offset += count
        }
    }

    func debugEnvelope(_ i: Int) -> Float { envelopes[i] }
    func debugFloor(_ i: Int) -> Float { noiseFloors[i] }
    func debugGain(_ i: Int) -> Float { gains[i] }

    private func coefficient(forMilliseconds ms: Float) -> Float {
        guard ms > 0 else { return 0 }
        return expf(-1 / (ms * 0.001 * sampleRate))
    }
}
