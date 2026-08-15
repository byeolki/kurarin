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

    /// Sliding-window maximum, kept as a monotonic queue: magnitudes in
    /// descending order, so the largest in the window is always at the front.
    ///
    /// The obvious implementation rescans the window for every sample, which at
    /// a 2 ms look-ahead is ninety-six comparisons per sample — several million
    /// a second spent rediscovering a number that mostly has not changed. A
    /// value with a larger one ahead of it can never be the maximum again, so
    /// dropping it on arrival makes each sample amortised constant work.
    private var queuedPeaks: [Float]
    private var queuedPositions: [Int]
    private var queueHead = 0
    private var queueTail = 0
    private var position = 0

    public init(sampleRate: Float, lookaheadMs: Float = 2) {
        self.sampleRate = sampleRate
        self.lookaheadFrames = max(1, Int(lookaheadMs * 0.001 * sampleRate))
        self.delayLine = [Float](repeating: 0, count: lookaheadFrames)
        self.queuedPeaks = [Float](repeating: 0, count: lookaheadFrames)
        self.queuedPositions = [Int](repeating: 0, count: lookaheadFrames)
    }

    public func reset() {
        for i in delayLine.indices { delayLine[i] = 0 }
        for i in queuedPeaks.indices { queuedPeaks[i] = 0 }
        for i in queuedPositions.indices { queuedPositions[i] = 0 }
        writeIndex = 0
        queueHead = 0
        queueTail = 0
        position = 0
        gain = 1
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let ceiling = powf(10, ceilingDB / 20)
        let releaseCoefficient = releaseMs > 0
            ? expf(-1 / (releaseMs * 0.001 * sampleRate))
            : 0

        let capacity = lookaheadFrames
        delayLine.withUnsafeMutableBufferPointer { delay in
            queuedPeaks.withUnsafeMutableBufferPointer { peaks in
                queuedPositions.withUnsafeMutableBufferPointer { positions in
                    for i in 0..<frameCount {
                        let input = buffer[i]
                        let magnitude = abs(input)

                        let delayed = delay[writeIndex]
                        delay[writeIndex] = input

                        // Retire what has left the window first, so the queue
                        // can never hold more entries than the window has
                        // samples.
                        while queueTail > queueHead,
                              positions[queueHead % capacity] <= position - capacity {
                            queueHead += 1
                        }
                        // Anything no larger than the arriving sample is now
                        // shadowed by it for the rest of its life in the window.
                        while queueTail > queueHead,
                              peaks[(queueTail - 1) % capacity] <= magnitude {
                            queueTail -= 1
                        }
                        peaks[queueTail % capacity] = magnitude
                        positions[queueTail % capacity] = position
                        queueTail += 1

                        let windowPeak = peaks[queueHead % capacity]

                        let requiredGain = windowPeak > ceiling ? ceiling / windowPeak : 1
                        if requiredGain < gain {
                            // Attack is instantaneous: the peak has not arrived yet.
                            gain = requiredGain
                        } else {
                            gain = requiredGain + (gain - requiredGain) * releaseCoefficient
                        }

                        buffer[i] = delayed * gain
                        writeIndex = (writeIndex + 1) % delay.count
                        position += 1
                    }
                }
            }
        }
    }
}
