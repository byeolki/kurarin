import CoreAudio
import Foundation

/// A stand-in for the buffer list an aggregate device hands the callback.
///
/// Core Audio is free to pack the channels as one interleaved block, as one
/// buffer per sub-device, or as one buffer per channel, and the routing code
/// has to handle all three. The fixture builds whichever shape a test asks for
/// and addresses channels the way the engine thinks of them: by their position
/// across the whole list.
final class BufferListFixture {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int
    private let channelsPerBuffer: [Int]
    /// Per buffer, because a test may hand the router a buffer shorter than the
    /// block. Every access is clamped to it: writing past a short buffer would
    /// corrupt the heap and turn a failing assertion into a hung test run.
    private let framesPerBuffer: [Int]
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(channelsPerBuffer: [Int], frames: Int, framesInBuffer: [Int]? = nil) {
        self.frames = frames
        self.channelsPerBuffer = channelsPerBuffer
        self.framesPerBuffer = framesInBuffer ?? [Int](repeating: frames, count: channelsPerBuffer.count)
        list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)

        for (index, channels) in channelsPerBuffer.enumerated() {
            // A buffer is allowed to be shorter than the block; the router has
            // to stop at what it was given rather than at what it was asked for.
            let bufferFrames = framesInBuffer?[index] ?? frames
            let count = channels * bufferFrames
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
            pointer.initialize(repeating: 0, count: max(count, 1))
            storage.append(pointer)

            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer)
            )
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    /// Locates a channel by its index across the whole list.
    private func location(of channel: Int) -> (buffer: Int, channelInBuffer: Int)? {
        var cursor = 0
        for (index, channels) in channelsPerBuffer.enumerated() {
            if channel < cursor + channels {
                return (index, channel - cursor)
            }
            cursor += channels
        }
        return nil
    }

    func set(channel: Int, frame: Int, to value: Float) {
        guard let location = location(of: channel), frame < framesPerBuffer[location.buffer] else { return }
        let channels = channelsPerBuffer[location.buffer]
        storage[location.buffer][frame * channels + location.channelInBuffer] = value
    }

    func fill(channel: Int, with value: Float) {
        for frame in 0..<frames { set(channel: channel, frame: frame, to: value) }
    }

    func value(channel: Int, frame: Int) -> Float {
        guard let location = location(of: channel), frame < framesPerBuffer[location.buffer] else { return .nan }
        let channels = channelsPerBuffer[location.buffer]
        return storage[location.buffer][frame * channels + location.channelInBuffer]
    }

    func channelValues(frame: Int) -> [Float] {
        (0..<channelsPerBuffer.reduce(0, +)).map { value(channel: $0, frame: frame) }
    }
}

/// A mono destination buffer with the same lifetime rules as the engine's.
final class MonoBuffer {
    let pointer: UnsafeMutablePointer<Float>
    let frames: Int

    init(frames: Int, filledWith value: Float = 0) {
        self.frames = frames
        pointer = .allocate(capacity: frames)
        pointer.initialize(repeating: value, count: frames)
    }

    deinit { pointer.deallocate() }

    var values: [Float] { (0..<frames).map { pointer[$0] } }
}
