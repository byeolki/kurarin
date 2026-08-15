import CoreAudio

/// Moves audio between the aggregate device's channels and the engine's mono
/// working buffers.
///
/// An aggregate hands the callback every sub-device's channels in one buffer
/// list, and how they are packed is not up to us: it may be one interleaved
/// block or one buffer per sub-device, per stream, or per channel. So channels
/// are located by walking the list and counting, never by indexing into a
/// single block.
///
/// Pulled out of the engine because this is the part most likely to be subtly
/// wrong on hardware nobody has tested yet, and it is the only part of the
/// routing that can be tested without any hardware at all.
enum ChannelRouter {
    /// Sums a range of channels down to mono, adding into `destination`.
    ///
    /// Adds rather than overwrites, so the caller is responsible for clearing
    /// the destination first — which the render callback does for every buffer
    /// at the top of the block.
    static func readMono(
        from list: UnsafeMutableAudioBufferListPointer,
        channelOffset: Int,
        channelCount: Int,
        into destination: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        guard channelCount > 0, frames > 0 else { return }

        var copied = 0
        forEachOverlap(in: list, channelOffset: channelOffset, channelCount: channelCount) {
            samples, channels, channelRange, available in
            let usable = min(frames, available)
            for channel in channelRange {
                for frame in 0..<usable {
                    destination[frame] += samples[frame * channels + channel]
                }
                copied += 1
            }
        }

        // A stereo microphone becomes the average of its channels, not the sum:
        // summing would make a centred voice 6 dB louder than the same voice on
        // a mono interface.
        if copied > 1 {
            let scale = 1 / Float(copied)
            for frame in 0..<frames { destination[frame] *= scale }
        }
    }

    /// Writes one mono signal to every channel in a range.
    static func write(
        _ source: UnsafePointer<Float>,
        into list: UnsafeMutableAudioBufferListPointer,
        channelOffset: Int,
        channelCount: Int,
        frames: Int,
        gain: Float
    ) {
        guard channelCount > 0, frames > 0 else { return }

        forEachOverlap(in: list, channelOffset: channelOffset, channelCount: channelCount) {
            samples, channels, channelRange, available in
            let usable = min(frames, available)
            for channel in channelRange {
                for frame in 0..<usable {
                    samples[frame * channels + channel] = source[frame] * gain
                }
            }
        }
    }

    /// Fills a whole buffer list with silence.
    static func silence(_ list: UnsafeMutableAudioBufferListPointer) {
        for buffer in list {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    /// Visits each buffer that holds part of `channelOffset ..< +channelCount`,
    /// handing over the buffer's channel indices that fall inside the range.
    private static func forEachOverlap(
        in list: UnsafeMutableAudioBufferListPointer,
        channelOffset: Int,
        channelCount: Int,
        body: (
            _ samples: UnsafeMutablePointer<Float>,
            _ channelsInBuffer: Int,
            _ channelRange: Range<Int>,
            _ availableFrames: Int
        ) -> Void
    ) {
        var cursor = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }

            let bufferStart = cursor
            cursor += channels
            // Overlap test against the half-open range the caller asked for.
            guard cursor > channelOffset, bufferStart < channelOffset + channelCount else { continue }

            let first = max(channelOffset - bufferStart, 0)
            let last = min(channelOffset + channelCount - bufferStart, channels)
            guard first < last else { continue }

            body(
                data.assumingMemoryBound(to: Float.self),
                channels,
                first..<last,
                Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            )
        }
    }
}
