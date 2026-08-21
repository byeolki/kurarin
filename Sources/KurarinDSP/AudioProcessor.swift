import Foundation

/// A mono, in-place audio processing unit.
///
/// Every unit preallocates its state at construction. `process` runs on the
/// real-time audio thread, so implementations must not allocate, lock, or call
/// into anything that might.
public protocol AudioProcessor: AnyObject {
    /// Clears any accumulated state without changing parameters.
    func reset()

    /// Transforms `frameCount` samples in place.
    func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int)
}

public extension AudioProcessor {
    /// Convenience for tests and offline use. Not real-time safe.
    func process(_ samples: [Float]) -> [Float] {
        var copy = samples
        copy.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            process(base, frameCount: buffer.count)
        }
        return copy
    }
}

/// How much algorithmic delay the voice shifter is allowed to introduce.
///
/// The floor is set by the lowest fundamental the pitch tracker must resolve:
/// PSOLA needs a couple of glottal periods in hand, and one period of a 60 Hz
/// voice is already 16.7 ms.
public enum LatencyMode: String, Codable, CaseIterable, Sendable {
    case low
    case balanced
    case quality

    /// Lowest fundamental frequency the pitch tracker will look for.
    public var minimumPitchHz: Float {
        switch self {
        case .low:      return 100
        case .balanced: return 75
        case .quality:  return 60
        }
    }

    /// How often the pitch tracker re-runs, in frames.
    ///
    /// Not a transform hop: nothing in this chain takes a spectrum. What the
    /// number buys is how quickly a pitch change is noticed, against the cost
    /// of running YIN that often. The modes that reach a lower fundamental
    /// need a longer correlation window, so they also analyse less often.
    public var hopSize: Int {
        switch self {
        case .low:      return 128
        case .balanced: return 256
        case .quality:  return 512
        }
    }
}
