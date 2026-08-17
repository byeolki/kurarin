import Foundation

/// Splits a signal into bands, measures each one, and puts it back together.
///
/// Two different jobs that pull in opposite directions, so this does them with
/// two different sets of filters.
///
/// **Putting it back together** wants differences of lowpasses. `LP(f2) - LP(f1)`
/// telescopes: with every band left alone the sum is exactly the input, and
/// with the bands scaled differently the result is a smooth curve rather than
/// a comb. Real bandpasses cannot do this — they are individually clean but
/// they arrive at the crossovers out of phase with each other, and summing them
/// digs a hole. Measured with edges at 200, 800, 3000 and 9000 Hz: nearly three
/// decibels down at every crossover, which is audible as coloration on a
/// filterbank that is supposed to be doing nothing.
///
/// **Measuring** wants the opposite. A telescoping band has no lower bound in
/// any real sense: subtracting a lowpass from its own source leaves the phase
/// difference between them, and an octave below the corner that difference is
/// most of the signal. Measured with edges at 500 and 2000 Hz and a 1 kHz tone:
/// the top band came out *louder than the input*. Every band therefore carried
/// a copy of whatever sat below it, which is how one unit's noise floors ended
/// up following the vowel and another's rebuilt air ended up tracking a
/// crossover's residue.
///
/// So: bandpasses to find out how loud each band is, lowpass differences to
/// carry the audio. The measurement filters are gentler — one section rather
/// than two — because a level does not need the same precision as a signal.
///
/// What this bank cannot do is carve. Scaling one band differently from its
/// neighbours leaves the phase residue they used to cancel between them, so a
/// band turned to zero attenuates its range rather than removing it. That is
/// the right trade here — the callers pull a noise floor down a few decibels
/// across several neighbouring bands, and none of them wants a hole — but a
/// caller that needs a band gone will not get it from this.
final class Filterbank {
    /// Number of bands, one more than the number of edges.
    let bandCount: Int

    private let capacity: Int
    private let hasFloor: Bool

    /// Carries the audio. Two sections: one is too gentle a slope to keep a
    /// loud band out of a quiet neighbour.
    private var lowpasses: [[Biquad]]
    /// Measures it. One section each, since this only produces a number.
    private var analysisHigh: [Biquad]
    private var analysisLow: [Biquad]
    /// Applies the floor to the audio as well as to the measurement.
    ///
    /// A telescoping split has no bottom by construction — the lowest band is
    /// everything below the first edge — so a bank told that its input starts
    /// at five kilohertz would otherwise happily rebuild content at fifty. The
    /// floor is what makes "this bank deals with the air above the voice" true
    /// of the signal it produces and not only of the numbers it reports.
    private var reconstructionHigh: [Biquad]

    private var source: [Float]
    private var previousLow: [Float]
    private var currentLow: [Float]
    private var band: [Float]
    private var measured: [Float]

    /// - Parameters:
    ///   - edges: crossover frequencies, ascending.
    ///   - floor: frequency below which the input is not expected to have
    ///     content, used when measuring the lowest band. Zero leaves it open.
    init(sampleRate: Float, edges: [Float], floor: Float = 0, capacity: Int = 512) {
        self.capacity = capacity
        hasFloor = floor > 0
        bandCount = edges.count + 1

        lowpasses = edges.map { frequency in
            (0..<2).map { _ -> Biquad in
                let filter = Biquad(sampleRate: sampleRate)
                filter.configure(kind: .lowpass, frequency: frequency, q: 0.707)
                return filter
            }
        }
        analysisHigh = ([floor] + edges).map { frequency in
            let filter = Biquad(sampleRate: sampleRate)
            if frequency > 0 {
                filter.configure(kind: .highpass, frequency: frequency, q: 0.707)
            }
            return filter
        }
        analysisLow = edges.map { frequency in
            let filter = Biquad(sampleRate: sampleRate)
            filter.configure(kind: .lowpass, frequency: frequency, q: 0.707)
            return filter
        }

        reconstructionHigh = floor > 0
            ? (0..<2).map { _ -> Biquad in
                let filter = Biquad(sampleRate: sampleRate)
                filter.configure(kind: .highpass, frequency: floor, q: 0.707)
                return filter
            }
            : []

        source = [Float](repeating: 0, count: capacity)
        previousLow = [Float](repeating: 0, count: capacity)
        currentLow = [Float](repeating: 0, count: capacity)
        band = [Float](repeating: 0, count: capacity)
        measured = [Float](repeating: 0, count: capacity)
    }

    /// Moves the crossovers. Recomputes coefficients, so it belongs on the
    /// parameter path rather than in a callback.
    func setEdges(_ newEdges: [Float], floor: Float? = nil) {
        precondition(newEdges.count == lowpasses.count)
        for (index, frequency) in newEdges.enumerated() {
            lowpasses[index].forEach {
                $0.configure(kind: .lowpass, frequency: frequency, q: 0.707)
            }
            analysisLow[index].configure(kind: .lowpass, frequency: frequency, q: 0.707)
            analysisHigh[index + 1].configure(kind: .highpass, frequency: frequency, q: 0.707)
        }
        if let floor, floor > 0 {
            analysisHigh[0].configure(kind: .highpass, frequency: floor, q: 0.707)
            reconstructionHigh.forEach {
                $0.configure(kind: .highpass, frequency: floor, q: 0.707)
            }
        }
    }

    func reset() {
        lowpasses.forEach { $0.forEach { $0.reset() } }
        analysisHigh.forEach { $0.reset() }
        analysisLow.forEach { $0.reset() }
        reconstructionHigh.forEach { $0.reset() }
    }

    /// Measures each band's level and applies whatever gain the caller returns.
    ///
    /// - Parameter gain: given the band index, its root mean square over this
    ///   chunk, and how many frames that chunk was, returns the factor to apply
    ///   to it. The frame count is there so a caller can express its time
    ///   constants in seconds: the bank works in chunks, and how many of those
    ///   arrive per second is the host's choice, not the caller's.
    func process(
        _ buffer: UnsafeMutablePointer<Float>,
        frameCount: Int,
        gain: (_ bandIndex: Int, _ level: Float, _ frames: Int) -> Float
    ) {
        var offset = 0
        while offset < frameCount {
            let count = min(frameCount - offset, capacity)
            processChunk(buffer + offset, count: count, gain: gain)
            offset += count
        }
    }

    /// Measures without touching the signal.
    func measure(
        _ buffer: UnsafePointer<Float>,
        frameCount: Int,
        level: (_ bandIndex: Int, _ level: Float, _ frames: Int) -> Void
    ) {
        var offset = 0
        while offset < frameCount {
            let count = min(frameCount - offset, capacity)
            for i in 0..<count { source[i] = buffer[offset + i] }
            for index in 0..<bandCount {
                level(index, measureBand(index, count: count), count)
            }
            offset += count
        }
    }

    private func processChunk(
        _ buffer: UnsafeMutablePointer<Float>,
        count: Int,
        gain: (Int, Float, Int) -> Float
    ) {
        for i in 0..<count {
            source[i] = buffer[i]
            previousLow[i] = 0
            buffer[i] = 0
        }

        if !reconstructionHigh.isEmpty {
            source.withUnsafeMutableBufferPointer { base in
                guard let pointer = base.baseAddress else { return }
                reconstructionHigh.forEach { $0.process(pointer, frameCount: count) }
            }
        }

        for index in 0..<bandCount {
            let level = measureBand(index, count: count)

            if index < lowpasses.count {
                for i in 0..<count { currentLow[i] = source[i] }
                currentLow.withUnsafeMutableBufferPointer { low in
                    guard let base = low.baseAddress else { return }
                    lowpasses[index].forEach { $0.process(base, frameCount: count) }
                }
                for i in 0..<count { band[i] = currentLow[i] - previousLow[i] }
            } else {
                for i in 0..<count { band[i] = source[i] - previousLow[i] }
            }

            let factor = gain(index, level, count)
            for i in 0..<count { buffer[i] += band[i] * factor }

            if index < lowpasses.count {
                for i in 0..<count { previousLow[i] = currentLow[i] }
            }
        }
    }

    /// Root mean square of one band of the current `source`, through the
    /// measurement filters.
    private func measureBand(_ index: Int, count: Int) -> Float {
        for i in 0..<count { measured[i] = source[i] }

        var sum: Float = 0
        measured.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            if index > 0 || hasFloor {
                analysisHigh[index].process(base, frameCount: count)
            }
            if index < analysisLow.count {
                analysisLow[index].process(base, frameCount: count)
            }
            for i in 0..<count { sum += base[i] * base[i] }
        }
        return count > 0 ? sqrtf(sum / Float(count)) : 0
    }
}
