import KurarinAtomics

/// Hands a value from a control thread to the audio thread in one piece.
///
/// Writing a parameter set field by field lets the audio thread observe half of
/// the old set and half of the new one. For a gain that is inaudible, but a
/// biquad whose feedback coefficients come from a different set than its
/// feedforward ones can be momentarily unstable, and an unstable filter is a
/// crack in the middle of a sentence rather than a smooth change.
///
/// Three preallocated slots and a publish count that only ever goes up. The
/// writer fills the slot the count is about to point at and then publishes the
/// count; the reader takes the count, copies the slot, and takes the count
/// again — if it moved, what it copied may be half of two different sets, so
/// it tries once more.
///
/// Checking afterwards is the part that matters. Three slots alone make tearing
/// unlikely rather than impossible: it takes three publishes inside one copy,
/// which no hand on a slider produces but a preempted thread eventually meets.
/// This test caught it once in about two hundred thousand reads. Comparing a
/// count that never repeats turns "unlikely" into "detected", and the reader
/// retries instead of returning nonsense.
public final class ParameterSlot<Value: BitwiseCopyable>: @unchecked Sendable {
    private static var slotCount: Int { 3 }

    private let storage: UnsafeMutablePointer<Value>
    private let index: UnsafeMutablePointer<KurarinAtomicIndex>

    public init(_ initial: Value) {
        storage = .allocate(capacity: ParameterSlot.slotCount)
        storage.initialize(repeating: initial, count: ParameterSlot.slotCount)
        index = .allocate(capacity: 1)
        kurarin_atomic_init(index)
    }

    deinit {
        storage.deinitialize(count: ParameterSlot.slotCount)
        storage.deallocate()
        index.deallocate()
    }

    /// Control thread only. Never blocks the reader.
    public func publish(_ value: Value) {
        // The count is the writer's own; only the store has to be atomic.
        published += 1
        storage[published % ParameterSlot.slotCount] = value
        kurarin_atomic_store_release(index, published)
    }

    /// Safe to call from the audio thread: a couple of atomic loads and one
    /// copy of a trivial value, with no allocation, no reference counting and
    /// no lock. The retry cannot spin for long — the writer is a person moving
    /// a control, not another audio thread — and it gives up rather than
    /// looping forever if it somehow does.
    public func load() -> Value {
        for _ in 0..<8 {
            let before = kurarin_atomic_load_acquire(index)
            let value = storage[before % ParameterSlot.slotCount]
            // A fence, not another acquire load. Acquire stops later reads from
            // moving earlier and says nothing about earlier reads moving later,
            // so without this the copy above is free to drift past the check
            // below and a torn read passes it.
            kurarin_atomic_acquire_fence()
            if kurarin_atomic_load_relaxed(index) == before { return value }
        }
        return storage[kurarin_atomic_load_acquire(index) % ParameterSlot.slotCount]
    }

    /// Written and read only by the publishing thread.
    private var published = 0
}
