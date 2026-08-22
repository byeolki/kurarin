import Foundation

/// Removes mouse clicks, key presses and desk thumps without eating the voice.
///
/// These noises have nothing in common with each other acoustically except the
/// shape of their envelope: they arrive far faster than a voice can, they are
/// over within a few milliseconds, and — the part that matters most — they
/// happen in every part of the spectrum at once. A key press is a piece of
/// plastic hitting a piece of plastic; it has no pitch, so its energy is spread
/// everywhere simultaneously. A voice does not do that. Even a plosive builds
/// its bands unevenly, and a vowel sits in a few narrow places.
///
/// So the detector works in eight bands rather than on the signal as a whole,
/// and asks two questions of each block: which bands just jumped, and how many
/// of them jumped together. Only the bands that jumped are ducked, which is
/// the difference between a click disappearing and a hole being punched in the
/// voice underneath it. The count is what separates a keyboard from a
/// consonant: half the spectrum arriving at once is not something a vocal tract
/// can do.
///
/// The reason ordinary noise suppression chews up a held "aaah" is that it
/// decides what to remove from level alone, and a steady vowel that starts
/// after a quiet passage looks like an onset. This one is told, per block,
/// whether the signal is voiced. A voiced frame is periodic — vowels are, key
/// presses are not — and while it is voiced the detector is deliberately made
/// hard of hearing: the threshold rises and the ducking shallows, so a
/// sustained note is left alone even as it swells.
///
/// A duck that starts when the click has already been heard is useless, so the
/// signal is delayed by a few milliseconds and the gain reduction is applied to
/// audio that has not been emitted yet — the same trick as the limiter, for the
/// same reason.
public final class TransientSuppressor: AudioProcessor {
    /// 0 leaves the signal alone; 1 ducks hard on anything sudden.
    public var strength: Float = 0
    /// Set once per block from the shared pitch tracker. The whole difference
    /// between this and a level gate.
    public var isVoiced: Bool = false

    public let lookaheadFrames: Int

    /// Wide enough to place a click, few enough to stay cheap. The exact edges
    /// matter less than the count: what is being measured is how much of the
    /// spectrum moved at once.
    private static let crossovers: [Float] = [200, 500, 1000, 2000, 3500, 6000, 10000]

    /// How much of the spectrum has to jump together before this is treated as
    /// something struck rather than something spoken.
    ///
    /// Two of eight, which sounds lax and is not. A held vowel never puts a
    /// single band over its own threshold, so the count is not what keeps the
    /// voice safe — the per-band thresholds and the sustained limit do that.
    /// What the count rules out is one band alone going over, which is what a
    /// consonant or a note starting looks like. Measured on the test signals: a
    /// quiet click reaches two bands, a knock through speech four, a loud click
    /// all eight, and a held vowel none.
    private static let simultaneousBands = 2

    /// Measured per chunk, so the chunk has to be short enough to see a click
    /// rather than average it away. A key press is over in three milliseconds;
    /// this is one and a third.
    private static let chunk = 64

    private let sampleRate: Float
    private var delayLine: [Float]
    private var writeIndex = 0

    /// The detector runs on what has just arrived; the ducking is applied to
    /// what is about to leave the delay line, which is what buys the lookahead.
    private let detector: Filterbank
    private let ducker: Filterbank
    private let bandCount: Int

    /// Three time scales, per band. The fast one sees the attack; the medium
    /// one is what the voice itself is doing right now, which is the only fair
    /// thing to compare an attack against; the slow one is the room, used as a
    /// floor so that near-silence does not make every sound look sudden.
    private var fast: [Float]
    private var medium: [Float]
    private var slow: [Float]
    private var gains: [Float]
    private var holdChunks: [Int]
    /// How long each band has been above its threshold. A click is over in a
    /// couple of milliseconds; anything still loud after that is a sound the
    /// speaker is making on purpose.
    private var elevated: [Int]
    private var quiet: [Int]
    /// Set when a duck turns out to have been aimed at a voice. Recovery from a
    /// mistake should be quick — the sound being restored is one the listener
    /// is waiting for — while recovery after a real click can afford to be
    /// gentle, because there is nothing underneath it to restore.
    private var misfire: [Bool]
    /// Written by the detector pass, read by the ducking pass.
    private var struck: [Bool]

    public init(sampleRate: Float, lookaheadMs: Float = 4) {
        self.sampleRate = sampleRate
        self.lookaheadFrames = max(1, Int(lookaheadMs * 0.001 * sampleRate))
        self.delayLine = [Float](repeating: 0, count: lookaheadFrames)

        detector = Filterbank(sampleRate: sampleRate, edges: TransientSuppressor.crossovers,
                              capacity: TransientSuppressor.chunk)
        ducker = Filterbank(sampleRate: sampleRate, edges: TransientSuppressor.crossovers,
                            capacity: TransientSuppressor.chunk)
        bandCount = detector.bandCount

        fast = [Float](repeating: 0, count: bandCount)
        medium = [Float](repeating: 0, count: bandCount)
        slow = [Float](repeating: 0, count: bandCount)
        gains = [Float](repeating: 1, count: bandCount)
        holdChunks = [Int](repeating: 0, count: bandCount)
        elevated = [Int](repeating: 0, count: bandCount)
        quiet = [Int](repeating: 0, count: bandCount)
        misfire = [Bool](repeating: false, count: bandCount)
        struck = [Bool](repeating: false, count: bandCount)
    }

    public func reset() {
        for i in delayLine.indices { delayLine[i] = 0 }
        writeIndex = 0
        detector.reset()
        ducker.reset()
        for i in 0..<bandCount {
            fast[i] = 0; medium[i] = 0; slow[i] = 0
            gains[i] = 1; holdChunks[i] = 0
            elevated[i] = 0; quiet[i] = 0
            misfire[i] = false; struck[i] = false
        }
    }

    /// Everything the detector needs that is fixed for the length of one block.
    private struct BlockSettings {
        let fast: Float
        let medium: Float
        let slow: Float
        let release: Float
        let recovery: Float
        let holdChunks: Int
        /// Past this, whatever it is, it is not a click.
        let sustainedLimit: Int
        /// Long enough to cross the gap between glottal pulses of even a deep
        /// voice, short enough that two separate clicks are still two events.
        let bridgeChunks: Int
        /// Measured against what the voice is doing right now rather than
        /// against the room: a knock is only a little louder than a shout in
        /// absolute terms, but it gets there in a fraction of the time.
        /// Voicing asks for more before acting, because ducking is audible
        /// against a held note and consonants are transients too.
        let ratioThreshold: Float
        /// How far down a detected transient is pushed. Shallower while
        /// voiced, where the cure is more audible than the disease.
        let duckGain: Float
    }

    private func settings(amount: Float) -> BlockSettings {
        let depth = (isVoiced ? 0.6 : 1) * amount
        let chunks = Float(TransientSuppressor.chunk) / sampleRate
        func perChunk(_ seconds: Float) -> Float { expf(-chunks / seconds) }
        return BlockSettings(
            fast: perChunk(0.001),
            medium: perChunk(0.015),
            slow: perChunk(0.200),
            release: perChunk(0.040),
            recovery: perChunk(0.004),
            holdChunks: max(1, Int(0.010 * sampleRate) / TransientSuppressor.chunk),
            sustainedLimit: max(1, Int(0.010 * sampleRate) / TransientSuppressor.chunk),
            bridgeChunks: max(1, Int(0.020 * sampleRate) / TransientSuppressor.chunk),
            ratioThreshold: isVoiced ? 3.2 : 2.2,
            duckGain: 1 - 0.95 * depth
        )
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let amount = min(max(strength, 0), 1)
        guard amount > 0.001 else {
            // Still has to run the delay line: a unit that stops delaying
            // mid-stream jumps the output forward by its own latency.
            passThrough(buffer, frameCount: frameCount)
            return
        }

        let settings = settings(amount: amount)

        // Chunk by chunk rather than block by block, and in this order: look at
        // what has just arrived, work out the gains it calls for, and only then
        // apply them to the audio leaving the delay line. Deciding for a whole
        // block at once would leave a click in the middle of it ducked by a
        // gain that had already recovered.
        var offset = 0
        while offset < frameCount {
            let count = min(TransientSuppressor.chunk, frameCount - offset)
            let block = buffer + offset

            detect(block, count: count, settings)

            delayLine.withUnsafeMutableBufferPointer { delay in
                for i in 0..<count {
                    let input = block[i]
                    block[i] = delay[writeIndex]
                    delay[writeIndex] = input
                    writeIndex = (writeIndex + 1) % delay.count
                }
            }

            ducker.process(block, frameCount: count) { index, _, _ in
                self.gains[index]
            }
            offset += count
        }

        for i in 0..<bandCount {
            fast[i] = withoutDenormals(fast[i])
            medium[i] = withoutDenormals(medium[i])
            slow[i] = withoutDenormals(slow[i])
            gains[i] = withoutDenormals(gains[i])
        }
    }

    /// Advances every band's envelopes and works out which of them, if any,
    /// were struck.
    private func detect(_ buffer: UnsafePointer<Float>, count: Int, _ settings: BlockSettings) {
        detector.measurePeak(buffer, frameCount: count) { index, peak, _ in
            self.follow(band: index, peak: peak, settings)
        }
        // Every band has now seen the same chunk, so the count that follows is
        // a statement about one moment rather than about the block.
        decide(settings)
    }

    private func follow(band index: Int, peak level: Float, _ settings: BlockSettings) {
        fast[index] = level > fast[index]
            ? level
            : fast[index] * settings.fast + level * (1 - settings.fast)
        // The medium and slow followers deliberately do not jump to a peak:
        // they are the thing being compared against, and a reference that leaps
        // with the click would hide it.
        medium[index] += (level - medium[index]) * (1 - settings.medium)
        slow[index] += (level - slow[index]) * (1 - settings.slow)

        // A floor on the reference: against digital silence every sound is
        // infinitely sudden, and the first word after a pause is not a click.
        let reference = max(medium[index], slow[index], 0.0015)
        let above = fast[index] > reference * settings.ratioThreshold
        quiet[index] = above ? 0 : quiet[index] + 1

        // A dip is not the end of a sound. Voiced speech is a train of pulses
        // with gaps between them, and a gap is longer than the click being
        // looked for — so the count keeps running across a short quiet stretch
        // and only a real silence resets it.
        if above || quiet[index] <= settings.bridgeChunks {
            elevated[index] += 1
        } else {
            elevated[index] = 0
        }

        struck[index] = above && elevated[index] <= settings.sustainedLimit
    }

    /// Turns per-band verdicts into per-band gains, but only once enough of the
    /// spectrum agrees.
    private func decide(_ settings: BlockSettings) {
        var together = 0
        for index in 0..<bandCount where struck[index] { together += 1 }
        let isStrike = together >= TransientSuppressor.simultaneousBands

        for index in 0..<bandCount {
            // Ducking only the bands that were struck is what stops a click
            // punching a hole in the voice underneath it. That only matters
            // while there is a voice: with nothing to protect, the whole
            // spectrum comes down and the click disappears rather than merely
            // narrowing.
            let ducked = isStrike && (struck[index] || !isVoiced)

            if ducked {
                holdChunks[index] = settings.holdChunks
            } else if elevated[index] > settings.sustainedLimit && holdChunks[index] > 0 {
                // Gone on too long to be a click: a vowel swelling, a word
                // starting, a note being held. Let go rather than strangle it —
                // and let go quickly, because what is being restored is
                // something the listener is waiting to hear.
                holdChunks[index] = 0
                misfire[index] = true
            }

            let target: Float
            if holdChunks[index] > 0 {
                holdChunks[index] -= 1
                target = settings.duckGain
            } else {
                target = 1
            }

            // Instant downwards, gentle upwards: the peak being ducked has not
            // left the delay line yet, so there is no need to ease into it,
            // while easing out avoids a click of its own.
            if target < gains[index] {
                gains[index] = target
            } else {
                let rate = misfire[index] ? settings.recovery : settings.release
                gains[index] = target + (gains[index] - target) * rate
                if gains[index] > 0.999 { misfire[index] = false }
            }
        }
    }

    private func passThrough(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        delayLine.withUnsafeMutableBufferPointer { delay in
            for i in 0..<frameCount {
                let input = buffer[i]
                buffer[i] = delay[writeIndex]
                delay[writeIndex] = input
                writeIndex = (writeIndex + 1) % delay.count
            }
        }
        for i in 0..<bandCount { gains[i] = 1; holdChunks[i] = 0 }
    }
}
