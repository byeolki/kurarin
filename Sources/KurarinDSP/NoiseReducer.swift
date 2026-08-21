import Foundation

/// Removes steady background noise — a fan, a computer, air conditioning, the
/// hiss of a cheap preamp — the sound that is there the whole time and that a
/// gate can only cut between words.
///
/// Each band learns how quiet it gets, and whatever sits at that level is
/// treated as noise and turned down. A band the voice is using stays open, so
/// the reduction happens where the noise is rather than across the whole
/// spectrum.
///
/// **Why not a spectrum.** The usual approach is an FFT, a noise profile per
/// bin, and a subtraction. It measures more precisely and costs two things this
/// cannot afford: a window of latency on a budget already at forty-odd
/// milliseconds, and musical noise — isolated bins surviving the subtraction
/// and warbling like water, which is the sound people recognise as "noise
/// suppression". Bands this wide cannot warble, and IIR filters have no window
/// to wait for.
///
/// **Why the estimator is told about voicing.** Steadiness cannot separate
/// noise from speech: a held vowel is steady too, and an estimator that learns
/// from whatever is steady eventually decides the vowel is the room. That is
/// exactly why "aaah" fades out halfway through on every other suppressor.
/// Periodicity can tell them apart, and the chain is already measuring it, so
/// the floor only rises while no voice is present.
public final class NoiseReducer: AudioProcessor {
    /// 0 is off. 1 removes as much as can be removed without the cure becoming
    /// more noticeable than the noise.
    public var strength: Float = 0
    public var isVoiced: Bool = false

    /// Sixteen bands, roughly a third of an octave through the range a voice
    /// and its noise share. Eight left too much of a fan audible between the
    /// bands the voice was using; many more than this and the bands are narrow
    /// enough to start warbling, which is the thing the whole design avoids.
    private static let crossovers: [Float] = [
        80, 125, 200, 315, 500, 700, 900, 1200,
        1600, 2200, 3000, 4000, 5500, 7500, 10000,
    ]

    private let sampleRate: Float
    private let bank: Filterbank

    /// The measured level, smoothed with a time constant of its own.
    ///
    /// A chunk's root mean square is a noisier estimate the shorter the chunk
    /// is, and the floor tracker follows dips quickly — so with small buffers it
    /// settles lower and subtracts less. Smoothing the measurement first makes
    /// the window that matters a duration rather than a buffer, and the host's
    /// choice of buffer stops changing how much noise comes out.
    private var levels: [Float]
    private var noiseFloors: [Float]
    private var gains: [Float]
    private var smoothed: [Float]
    /// Counted in samples, not in callbacks: the host picks the block size.
    private var warmUpBlocks: [Int]

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
        bank = Filterbank(sampleRate: sampleRate, edges: NoiseReducer.crossovers)

        levels = [Float](repeating: 0, count: bank.bandCount)
        noiseFloors = [Float](repeating: 0, count: bank.bandCount)
        gains = [Float](repeating: 1, count: bank.bandCount)
        smoothed = [Float](repeating: 1, count: bank.bandCount)
        warmUpBlocks = [Int](repeating: 0, count: bank.bandCount)
    }

    public func reset() {
        bank.reset()
        for i in noiseFloors.indices {
            levels[i] = 0
            noiseFloors[i] = 0
            gains[i] = 1
            smoothed[i] = 1
            warmUpBlocks[i] = 0
        }
    }

    /// The two numbers that decide how hard this block is cleaned. Fixed for
    /// its duration, because both depend only on the strength and the voicing
    /// verdict the caller sets before it starts.
    private struct BlockSettings {
        /// Over-subtraction: removing exactly the estimate leaves the noise
        /// audibly present, because the estimate is an average and the noise
        /// fluctuates around it. Removing rather more, with a floor under the
        /// gain so nothing is ever silenced completely, is what makes the
        /// result sound like a quieter room instead of a processed one.
        let over: Float
        let minimumGain: Float
        let warmUpSamples: Int
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard strength > 0.001 else {
            // The filters still have to see the signal, or switching on after a
            // silence starts from cold states and clicks.
            bank.process(buffer, frameCount: frameCount) { _, _, _ in 1 }
            return
        }

        let settings = BlockSettings(
            over: 1.5 + 2 * strength * (isVoiced ? 0.6 : 1),
            minimumGain: powf(10, -(5 + 15 * strength) / 20),
            warmUpSamples: Int(0.2 * sampleRate)
        )

        bank.process(buffer, frameCount: frameCount) { index, chunkLevel, frames in
            self.gain(forBand: index, chunkLevel: chunkLevel, frames: frames, settings)
        }
    }

    /// What one band's gain should be for one chunk: follow the level, follow
    /// the floor under it, subtract, then agree with the neighbours.
    private func gain(
        forBand index: Int,
        chunkLevel: Float,
        frames: Int,
        _ settings: BlockSettings
    ) -> Float {
        // Expressed in seconds and converted per chunk, so that a host handing
        // over sixty-four frames at a time and one handing over five hundred
        // and twelve get the same behaviour rather than one adapting eight
        // times faster than the other.
        let elapsed = Float(frames) / sampleRate

        let level = trackLevel(band: index, chunkLevel: chunkLevel, elapsed: elapsed)
        let floor = trackFloor(band: index, level: level, frames: frames, elapsed: elapsed, settings)

        guard warmUpBlocks[index] >= settings.warmUpSamples, level > 0 else {
            smoothed[index] = 1
            gains[index] = 1
            return 1
        }

        let target = subtractionGain(level: level, floor: floor, settings)
        return blendWithNeighbours(smooth(target, band: index, elapsed: elapsed), band: index)
    }

    /// Returns the level before denormal flushing, which is what the rest of
    /// the estimate compares against; the flushed value is what is kept.
    private func trackLevel(band index: Int, chunkLevel: Float, elapsed: Float) -> Float {
        var level = levels[index]
        level += (chunkLevel - level) * coefficient(0.020, elapsed)
        levels[index] = withoutDenormals(level)
        return level
    }

    /// Follows the quietest thing this band does, which is taken to be the
    /// room.
    private func trackFloor(
        band index: Int,
        level: Float,
        frames: Int,
        elapsed: Float,
        _ settings: BlockSettings
    ) -> Float {
        var floor = noiseFloors[index]

        if warmUpBlocks[index] < settings.warmUpSamples && !isVoiced {
            // Learning starts on the room, not on whoever is already talking.
            // Until something has been learned the gain stays at one: with no
            // estimate, the safe thing to do is nothing.
            warmUpBlocks[index] += frames
            floor = level
        } else if level < floor {
            // Downwards is always safe: it can only make the reduction more
            // cautious.
            floor += (level - floor) * coefficient(0.060, elapsed)
        } else if !isVoiced {
            floor += (level - floor) * coefficient(1.300, elapsed)
        }

        noiseFloors[index] = withoutDenormals(floor)
        return floor
    }

    /// Subtracted in power rather than in amplitude. A band carrying speech
    /// ten times above its noise loses a sixth of a decibel this way and a
    /// third of its amplitude the other — the difference between cleaning a
    /// signal and thinning it.
    private func subtractionGain(level: Float, floor: Float, _ settings: BlockSettings) -> Float {
        let ratio = floor / level
        let remaining = 1 - settings.over * ratio * ratio
        return remaining > 0 ? max(sqrtf(remaining), settings.minimumGain) : settings.minimumGain
    }

    /// Opening fast and closing slowly: the quick one belongs to the direction
    /// that gives the signal back, because a word starts in a couple of
    /// milliseconds and a reducer that takes eighty to get out of the way
    /// swallows the beginning of every sentence.
    private func smooth(_ target: Float, band index: Int, elapsed: Float) -> Float {
        var gain = smoothed[index]
        let rate = target > gain ? coefficient(0.005, elapsed) : coefficient(0.040, elapsed)
        gain += (target - gain) * rate
        smoothed[index] = withoutDenormals(gain)
        gains[index] = gain
        return gain
    }

    /// Averages in the band below's gain from this chunk and the band above's
    /// from the last one.
    ///
    /// The reconstruction sums differences of lowpasses, which is exact when
    /// the bands move together and leaves a phase residue when one band is
    /// pulled away from its neighbours — enough, in the worst case, to make a
    /// tone come back louder than it went in. A noise floor is broadband, so
    /// the gains want to move together anyway; this makes sure they do.
    private func blendWithNeighbours(_ gain: Float, band index: Int) -> Float {
        let below = index > 0 ? gains[index - 1] : gain
        let above = index + 1 < smoothed.count ? smoothed[index + 1] : gain
        return (below + 2 * gain + above) * 0.25
    }

    private func coefficient(_ seconds: Float, _ elapsed: Float) -> Float {
        1 - expf(-elapsed / seconds)
    }
}
