import Foundation
import KurarinAtomics

/// Single-producer, single-consumer lock-free ring for passing commands to the
/// audio thread.
///
/// The audio callback cannot take a lock: blocking there stalls the device and
/// produces an audible dropout, and it can deadlock against a UI thread holding
/// the same lock. A fixed ring with atomic indices lets the UI hand work over
/// without either side ever waiting on the other.
///
/// Overflow drops the newest command rather than blocking or growing. The queue
/// holds hundreds of slots and the audio thread drains it every few
/// milliseconds, so a full queue means something is already badly wrong and
/// losing a trigger is the mildest available response.
public final class CommandQueue<Command>: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Command?>
    private let head: UnsafeMutablePointer<KurarinAtomicIndex>
    private let tail: UnsafeMutablePointer<KurarinAtomicIndex>

    public init(capacity: Int = 256) {
        precondition(capacity > 1)
        self.capacity = capacity

        storage = UnsafeMutablePointer<Command?>.allocate(capacity: capacity)
        storage.initialize(repeating: nil, count: capacity)

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

    /// Called from the producer thread only.
    @discardableResult
    public func push(_ command: Command) -> Bool {
        let currentTail = kurarin_atomic_load_relaxed(tail)
        let next = (currentTail + 1) % capacity
        guard next != kurarin_atomic_load_acquire(head) else { return false }

        storage[currentTail] = command
        kurarin_atomic_store_release(tail, next)
        return true
    }

    /// Called from the consumer thread only. Nil when nothing is pending.
    public func pop() -> Command? {
        let currentHead = kurarin_atomic_load_relaxed(head)
        guard currentHead != kurarin_atomic_load_acquire(tail) else { return nil }

        let command = storage[currentHead]
        storage[currentHead] = nil
        kurarin_atomic_store_release(head, (currentHead + 1) % capacity)
        return command
    }

    public func drain(_ handle: (Command) -> Void) {
        while let command = pop() {
            handle(command)
        }
    }
}
