import Foundation
import KurarinAtomics

/// Single-producer, single-consumer ring of audio samples.
///
/// The audio thread has the finished mix and the recorder needs it, but the
/// recorder encodes and writes to disk — both of which take locks the audio
/// thread must never wait on. So the callback copies its block into a fixed
/// ring and returns, and the writer drains it on its own time.
///
/// `CommandQueue` next door does the same job for one message at a time. This
/// one moves blocks of samples, so it hands over spans rather than elements and
/// keeps count of what it had to drop.
public final class SampleRing: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head: UnsafeMutablePointer<KurarinAtomicIndex>
    private let tail: UnsafeMutablePointer<KurarinAtomicIndex>

    /// Samples the writer had nowhere to put.
    ///
    /// Only ever incremented by the audio thread and read by the recorder, and
    /// only interesting after the fact: a recording that dropped samples has a
    /// gap in it, and the user is better told than left to wonder why the
    /// sound drifts out of step with the picture.
    public private(set) var dropped: Int = 0

    /// - Parameter seconds: how far behind the writer the reader may fall
    ///   before samples start being lost. Disk writes stall for tens of
    ///   milliseconds at a time, so this is generously sized: two seconds of
    ///   mono at 48 kHz is under 400 kB.
    public init(sampleRate: Float = 48000, seconds: Float = 2) {
        capacity = max(1024, Int(sampleRate * seconds))
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        head = UnsafeMutablePointer<KurarinAtomicIndex>.allocate(capacity: 1)
        tail = UnsafeMutablePointer<KurarinAtomicIndex>.allocate(capacity: 1)
        kurarin_atomic_init(head)
        kurarin_atomic_init(tail)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        head.deallocate()
        tail.deallocate()
    }

    /// Producer side. Real-time safe: a bounded copy and one release store.
    ///
    /// A block that does not fit is dropped whole rather than in part. Half a
    /// block in the file is a click; a missing block is a gap the same length
    /// as the overrun, and the count says so.
    public func write(_ buffer: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let currentTail = kurarin_atomic_load_relaxed(tail)
        let currentHead = kurarin_atomic_load_acquire(head)

        // One slot is always left empty, so a full ring is distinguishable from
        // an empty one.
        let free = (currentHead + capacity - currentTail - 1) % capacity
        guard count <= free else {
            dropped += count
            return
        }

        let first = min(count, capacity - currentTail)
        storage.advanced(by: currentTail).update(from: buffer, count: first)
        if first < count {
            storage.update(from: buffer + first, count: count - first)
        }
        kurarin_atomic_store_release(tail, (currentTail + count) % capacity)
    }

    /// Consumer side. Returns how many samples were actually available.
    public func read(into buffer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let currentHead = kurarin_atomic_load_relaxed(head)
        let currentTail = kurarin_atomic_load_acquire(tail)

        let available = (currentTail + capacity - currentHead) % capacity
        let taking = min(count, available)
        guard taking > 0 else { return 0 }

        let first = min(taking, capacity - currentHead)
        buffer.update(from: storage.advanced(by: currentHead), count: first)
        if first < taking {
            (buffer + first).update(from: storage, count: taking - first)
        }
        kurarin_atomic_store_release(head, (currentHead + taking) % capacity)
        return taking
    }

    /// How many samples are waiting. Consumer side.
    public var available: Int {
        let currentHead = kurarin_atomic_load_relaxed(head)
        let currentTail = kurarin_atomic_load_acquire(tail)
        return (currentTail + capacity - currentHead) % capacity
    }

    /// Throws away anything pending and forgets the drop count. Not safe while
    /// either side is running; call it between recordings.
    public func reset() {
        kurarin_atomic_store_release(head, 0)
        kurarin_atomic_store_release(tail, 0)
        dropped = 0
    }
}
