import Foundation

/// Removes mains hum — the buzz a cheap interface, an unbalanced cable or a
/// laptop charger puts under everything.
///
/// The band-by-band reducer cannot touch this. Hum is a handful of very narrow
/// tones, and a band wide enough not to warble is far wider than they are, so
/// turning the band down to reach the hum takes the voice sharing that band
/// with it. What is needed is the opposite of wide: notches narrow enough to
/// sit between the harmonics of a voice.
///
/// The fundamental is usually the least of it. A high pass at eighty hertz —
/// which this chain has by default — already removes fifty and sixty. The
/// harmonics are the problem: a hundred, a hundred and twenty, a hundred and
/// eighty, two hundred and forty, sitting exactly where a speaking voice puts
/// its own fundamental, where they are heard as a buzz rather than as a hum.
///
/// **Found rather than assumed.** Fifty hertz in most of the world, sixty in
/// the Americas and parts of Japan, and neither if the room is quiet — notching
/// a frequency that carries no hum removes nothing and dents whatever the voice
/// had there. So the two candidates are measured against the level between
/// them, and the notches only engage when one of them stands well above it.
public final class HumRemover: AudioProcessor {
    /// 0 is off. Scales how deep the notches go, not how many there are.
    public var strength: Float = 0

    /// What was found, in hertz, or zero while nothing stands out.
    public private(set) var detectedHz: Float = 0

    /// Fundamental plus seven harmonics reaches four hundred hertz at fifty and
    /// four hundred and eighty at sixty, which is as far up as mains hum
    /// carries enough energy to hear over a voice.
    private static let harmonicCount = 8
    private static let candidates: [Float] = [50, 60]
    /// Measured too, as the level a real tone has to stand above.
    ///
    /// Well away from fifty, sixty and their harmonics, and averaged over
    /// three, because a single reference sitting near a candidate measures that
    /// candidate rather than the floor: a tone spreads across neighbouring
    /// frequencies, and how far it spreads depends on how long the window is.
    /// At one second the spread is about a hertz, so these three are clear of
    /// it; at a quarter of a second, which is where this started, fifty-five
    /// hertz sat inside the skirt of fifty and the two measured the same.
    private static let referencesHz: [Float] = [43, 71, 97]

    private let sampleRate: Float
    private var notches: [Biquad]

    /// Goertzel accumulators, one per frequency of interest.
    private var detectors: [Goertzel]
    /// Filled in place rather than mapped into a new array: this runs on the
    /// audio thread, where a malloc is a dropped buffer waiting for a contended
    /// allocator lock.
    private var magnitudes: [Float]
    private var windowRemaining: Int
    private let windowLength: Int

    /// The signal before the notches, kept so that how much hum is removed can
    /// be a blend rather than a filter setting.
    private var dry: [Float]
    private static let chunk = 1024

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
        // A second. Long enough to separate the candidates from the floor,
        // and hum does not come and go faster than someone can move a cable.
        windowLength = Int(1.0 * sampleRate)
        windowRemaining = windowLength

        notches = (0..<HumRemover.harmonicCount).map { _ in Biquad(sampleRate: sampleRate) }
        dry = [Float](repeating: 0, count: HumRemover.chunk)
        detectors = (HumRemover.candidates + HumRemover.referencesHz).map {
            Goertzel(frequency: $0, sampleRate: sampleRate)
        }
        magnitudes = [Float](repeating: 0, count: detectors.count)
    }

    public func reset() {
        notches.forEach { $0.reset() }
        detectors.indices.forEach { detectors[$0].reset() }
        windowRemaining = windowLength
        detectedHz = 0
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard strength > 0.001 else {
            // Including the half-finished window. Resuming a measurement across
            // a gap of arbitrary length measures a second of audio that was
            // never contiguous, and the first second after switching back on is
            // exactly when someone is listening for a difference.
            reset()
            return
        }

        detect(buffer, frameCount: frameCount)

        guard detectedHz > 0 else { return }

        // Depth by blending, not by filter gain. A notch at full depth is as
        // narrow as its quality factor says; a peaking filter cutting by the
        // same amount is not, and measured with eight of them at forty-two
        // decibels a voice lost ten decibels at its fundamental and sixteen at
        // its second harmonic — a hum remover that removes the speaker.
        let blend = min(max(strength, 0), 1)
        var offset = 0
        while offset < frameCount {
            let count = min(frameCount - offset, HumRemover.chunk)
            let block = buffer + offset

            for i in 0..<count { dry[i] = block[i] }
            for notch in notches {
                notch.process(block, frameCount: count)
            }
            for i in 0..<count {
                block[i] = dry[i] + (block[i] - dry[i]) * blend
            }
            offset += count
        }
    }

    private func detect(_ buffer: UnsafePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount {
            let sample = buffer[i]
            for index in detectors.indices {
                detectors[index].push(sample)
            }
        }

        windowRemaining -= frameCount
        guard windowRemaining <= 0 else { return }
        windowRemaining = windowLength

        for index in detectors.indices {
            magnitudes[index] = detectors[index].magnitude
            detectors[index].reset()
        }

        var referenceSum: Float = 0
        for index in HumRemover.candidates.count..<magnitudes.count {
            referenceSum += magnitudes[index]
        }
        let reference = max(referenceSum / Float(HumRemover.referencesHz.count), 1e-9)
        var bestFrequency: Float = 0
        var bestMagnitude: Float = 0
        for (index, frequency) in HumRemover.candidates.enumerated()
        where magnitudes[index] > bestMagnitude {
            bestMagnitude = magnitudes[index]
            bestFrequency = frequency
        }

        // Eight times the level between the candidates. A room with no hum
        // wanders around its noise floor and never clears this; a room with hum
        // clears it by a wide margin.
        // Only when it changes. Depth is a blend against the dry signal, so
        // strength does not touch the coefficients and moving that slider is no
        // reason to recompute eight biquads inside the callback.
        let found = bestMagnitude > reference * 8 ? bestFrequency : 0
        if found != detectedHz {
            detectedHz = found
            configure()
        }
    }

    private func configure() {
        guard detectedHz > 0 else { return }

        let nyquist = sampleRate * 0.45
        for (index, notch) in notches.enumerated() {
            let frequency = detectedHz * Float(index + 1)
            guard frequency < nyquist else {
                // Above the range, and left doing nothing rather than removed,
                // so the cascade stays the same length whatever was found.
                notch.configure(kind: .peaking, frequency: nyquist, q: 1, gainDB: 0)
                continue
            }
            // Narrow: a quality factor of thirty puts the skirts within a
            // couple of hertz, inside the gap between one harmonic of a voice
            // and the next.
            notch.configure(kind: .notch, frequency: frequency, q: 30)
        }
    }
}

/// Measures how much of one frequency a block of samples contains.
///
/// The textbook way to ask about a handful of frequencies without paying for a
/// whole transform: two multiplies and two adds per sample per frequency, and
/// the answer falls out of the state at the end of the window.
struct Goertzel {
    private let coefficient: Float
    private var previous: Float = 0
    private var previousButOne: Float = 0
    private var count: Int = 0

    init(frequency: Float, sampleRate: Float) {
        coefficient = 2 * cosf(2 * .pi * frequency / sampleRate)
    }

    mutating func push(_ sample: Float) {
        let current = sample + coefficient * previous - previousButOne
        previousButOne = previous
        previous = current
        count += 1
    }

    /// Root mean square of the component, comparable between frequencies.
    var magnitude: Float {
        guard count > 0 else { return 0 }
        let power = previous * previous + previousButOne * previousButOne
            - coefficient * previous * previousButOne
        return sqrtf(max(power, 0)) / Float(count)
    }

    mutating func reset() {
        previous = 0
        previousButOne = 0
        count = 0
    }
}
