import Foundation

/// Look-ahead brick wall limiter.
///
/// The last thing in the chain. A shifted voice and a soundboard hit landing on
/// the same frame will otherwise clip, and clipping on a virtual microphone is
/// especially unpleasant because the listener has no way to turn it down at the
/// source. Look-ahead lets the gain come down before the peak arrives instead
/// of after it, so there is no overshoot to clip.
public final class Limiter: AudioProcessor {
    public var ceilingDB: Float = -0.5
    public var releaseMs: Float = 60

    public let lookaheadFrames: Int

    private let sampleRate: Float
    private var delayLine: [Float]
    private var writeIndex: Int = 0
    private var gain: Float = 1
    /// Rolling maximum of the samples currently inside the look-ahead window.
    private var peakWindow: [Float]

    public init(sampleRate: Float, lookaheadMs: Float = 2) {
        self.sampleRate = sampleRate
        self.lookaheadFrames = max(1, Int(lookaheadMs * 0.001 * sampleRate))
        self.delayLine = [Float](repeating: 0, count: lookaheadFrames)
        self.peakWindow = [Float](repeating: 0, count: lookaheadFrames)
    }

    public func reset() {
        for i in delayLine.indices { delayLine[i] = 0 }
        for i in peakWindow.indices { peakWindow[i] = 0 }
        writeIndex = 0
        gain = 1
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let ceiling = powf(10, ceilingDB / 20)
        let releaseCoefficient = releaseMs > 0
            ? expf(-1 / (releaseMs * 0.001 * sampleRate))
            : 0

        delayLine.withUnsafeMutableBufferPointer { delay in
            peakWindow.withUnsafeMutableBufferPointer { peaks in
                for i in 0..<frameCount {
                    let input = buffer[i]

                    let delayed = delay[writeIndex]
                    delay[writeIndex] = input
                    peaks[writeIndex] = abs(input)

                    // Peak over the whole look-ahead window. The window is a
                    // couple of hundred samples, so a linear scan stays cheap
                    // and avoids the bookkeeping of a monotonic deque.
                    var windowPeak: Float = 0
                    for value in peaks where value > windowPeak {
                        windowPeak = value
                    }

                    let requiredGain = windowPeak > ceiling ? ceiling / windowPeak : 1
                    if requiredGain < gain {
                        // Attack is instantaneous: the peak has not arrived yet.
                        gain = requiredGain
                    } else {
                        gain = requiredGain + (gain - requiredGain) * releaseCoefficient
                    }

                    buffer[i] = delayed * gain
                    writeIndex = (writeIndex + 1) % delay.count
                }
            }
        }
    }
}
