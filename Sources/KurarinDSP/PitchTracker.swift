import Foundation

/// Fundamental frequency estimator based on the YIN algorithm.
///
/// The shifter needs two things from this: where the glottal periods are, and
/// whether the current sound is voiced at all. Fricatives have no period, and
/// slicing them on imaginary pitch marks turns them to mush, so an honest
/// voiced/unvoiced decision matters as much as the period itself.
///
/// Analysis runs on a decimated copy of the signal. YIN costs O(window × lag),
/// and at 48 kHz with a 60 Hz floor that is over a million operations per
/// estimate — far too much to run several hundred times a second. Voice
/// fundamentals live below 500 Hz, so a quarter-rate copy loses nothing that
/// matters and cuts the work by sixteen.
public final class PitchTracker {
    /// Below this, YIN's normalised difference is considered a real period.
    private static let voicingThreshold: Float = 0.2

    public let sampleRate: Float
    public let minimumHz: Float
    public let maximumHz: Float

    private let decimation: Int
    private let decimatedRate: Float
    private let minimumLag: Int
    private let maximumLag: Int
    private let windowSize: Int

    private let antiAlias1: Biquad
    private let antiAlias2: Biquad

    /// Decimated history, long enough for one analysis window plus the longest
    /// lag. Twice that is allocated so appending is a store rather than a shift;
    /// see `appendToHistory`.
    private var history: [Float]
    private let historySpan: Int
    private var historyFill: Int = 0
    private var decimationPhase: Int = 0
    private var filterScratch: [Float]

    private var difference: [Float]
    private var normalised: [Float]

    public private(set) var periodSamples: Float = 0
    public private(set) var isVoiced: Bool = false
    public private(set) var confidence: Float = 0

    public init(sampleRate: Float, minimumHz: Float, maximumHz: Float = 500) {
        self.sampleRate = sampleRate
        self.minimumHz = minimumHz
        self.maximumHz = maximumHz

        let target: Float = 12000
        decimation = max(1, Int((sampleRate / target).rounded()))
        decimatedRate = sampleRate / Float(decimation)

        minimumLag = max(2, Int(decimatedRate / maximumHz))
        maximumLag = Int(decimatedRate / minimumHz) + 1
        windowSize = maximumLag

        antiAlias1 = Biquad(sampleRate: sampleRate)
        antiAlias2 = Biquad(sampleRate: sampleRate)
        // Two cascaded sections put the fold-back region ~38 dB down, while
        // leaving the low harmonics YIN relies on untouched.
        antiAlias1.configure(kind: .lowpass, frequency: min(2000, sampleRate * 0.2), q: 0.541)
        antiAlias2.configure(kind: .lowpass, frequency: min(2000, sampleRate * 0.2), q: 1.307)

        historySpan = windowSize + maximumLag
        history = [Float](repeating: 0, count: historySpan * 2)
        filterScratch = [Float](repeating: 0, count: 4096)
        difference = [Float](repeating: 0, count: maximumLag + 1)
        normalised = [Float](repeating: 0, count: maximumLag + 1)
    }

    public func reset() {
        antiAlias1.reset()
        antiAlias2.reset()
        for i in history.indices { history[i] = 0 }
        historyFill = 0
        decimationPhase = 0
        periodSamples = 0
        isVoiced = false
        confidence = 0
    }

    /// Feeds new samples. Does not run an estimate — call `analyse` for that.
    public func push(_ buffer: UnsafePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let chunk = min(frameCount - offset, filterScratch.count)
            filterScratch.withUnsafeMutableBufferPointer { scratch in
                guard let base = scratch.baseAddress else { return }
                base.update(from: buffer + offset, count: chunk)
                antiAlias1.process(base, frameCount: chunk)
                antiAlias2.process(base, frameCount: chunk)

                for i in 0..<chunk {
                    decimationPhase += 1
                    if decimationPhase >= decimation {
                        decimationPhase = 0
                        appendToHistory(base[i])
                    }
                }
            }
            offset += chunk
        }
    }

    /// Appends one decimated sample, keeping the analysis window contiguous.
    ///
    /// YIN's inner loop is O(window × lag) and runs over this buffer, so the
    /// window has to be laid out flat — a wrap-around ring would put an index
    /// wrap inside the hottest loop in the project. The compromise is twice the
    /// storage: samples are appended until the far end is reached, and only
    /// then is the tail copied back to the front. That makes appending a plain
    /// store, with one bulk copy per span of samples rather than a copy of the
    /// whole span per sample.
    private func appendToHistory(_ sample: Float) {
        if historyFill == history.count {
            history.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                base.update(from: base + historySpan, count: historySpan)
            }
            historyFill = historySpan
        }

        history[historyFill] = sample
        historyFill += 1
    }

    /// Index of the oldest sample in the current analysis window.
    private var windowStart: Int { max(0, historyFill - historySpan) }

    /// Runs one estimate over the most recent history.
    ///
    /// Updates `periodSamples`, `isVoiced` and `confidence`. When the frame is
    /// unvoiced the previous period is left in place, so callers that want a
    /// plausible period during a fricative can keep using it.
    public func analyse() {
        guard historyFill >= historySpan else {
            isVoiced = false
            confidence = 0
            return
        }

        let start = windowStart
        history.withUnsafeBufferPointer { historyBuffer in
            guard let base = historyBuffer.baseAddress else { return }
            let x = base + start
            difference.withUnsafeMutableBufferPointer { diffBuffer in
                normalised.withUnsafeMutableBufferPointer { normBuffer in
                    guard let d = diffBuffer.baseAddress, let dPrime = normBuffer.baseAddress else { return }

                    d[0] = 0
                    for lag in 1...maximumLag {
                        var sum: Float = 0
                        for j in 0..<windowSize {
                            let delta = x[j] - x[j + lag]
                            sum += delta * delta
                        }
                        d[lag] = sum
                    }

                    // Cumulative mean normalisation. Without it the difference
                    // function is smallest at lag 0 and every octave error
                    // below the true period wins.
                    dPrime[0] = 1
                    var runningSum: Float = 0
                    for lag in 1...maximumLag {
                        runningSum += d[lag]
                        dPrime[lag] = runningSum > 0 ? d[lag] * Float(lag) / runningSum : 1
                    }

                    var chosenLag = -1
                    var lag = minimumLag
                    while lag <= maximumLag {
                        if dPrime[lag] < PitchTracker.voicingThreshold {
                            // Walk to the bottom of this dip rather than taking
                            // the first sample under the threshold.
                            while lag + 1 <= maximumLag && dPrime[lag + 1] < dPrime[lag] {
                                lag += 1
                            }
                            chosenLag = lag
                            break
                        }
                        lag += 1
                    }

                    if chosenLag < 0 {
                        var bestLag = minimumLag
                        var bestValue = dPrime[minimumLag]
                        for candidate in minimumLag...maximumLag where dPrime[candidate] < bestValue {
                            bestValue = dPrime[candidate]
                            bestLag = candidate
                        }
                        chosenLag = bestLag
                        isVoiced = false
                    } else {
                        isVoiced = true
                    }

                    confidence = max(0, 1 - dPrime[chosenLag])

                    // Parabolic interpolation recovers sub-sample resolution,
                    // which matters because the estimate is scaled back up by
                    // the decimation factor.
                    var refined = Float(chosenLag)
                    if chosenLag > minimumLag && chosenLag < maximumLag {
                        let before = dPrime[chosenLag - 1]
                        let here = dPrime[chosenLag]
                        let after = dPrime[chosenLag + 1]
                        let denominator = 2 * (2 * here - before - after)
                        if abs(denominator) > 1e-9 {
                            refined += (after - before) / denominator
                        }
                    }

                    if isVoiced {
                        periodSamples = refined * Float(decimation)
                    }
                }
            }
        }
    }
}
