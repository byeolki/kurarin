import KurarinAtomics

/// Hands a value from a control thread to the audio thread in one piece.
///
/// Writing a parameter set field by field lets the audio thread observe half of
/// the old set and half of the new one. For a gain that is inaudible, but a
/// biquad whose feedback coefficients come from a different set than its
/// feedforward ones can be momentarily unstable, and an unstable filter is a
/// crack in the middle of a sentence rather than a smooth change.
///
/// Three preallocated slots and one atomic index. The writer fills a slot the
/// reader cannot be holding and then publishes it; the reader takes the index
/// once and copies the whole set. Tearing would take three publishes landing
/// inside a single copy, which no human moving a slider can produce.
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
        let next = (kurarin_atomic_load_relaxed(index) + 1) % ParameterSlot.slotCount
        storage[next] = value
        kurarin_atomic_store_release(index, next)
    }

    /// Safe to call from the audio thread: one atomic load and one copy of a
    /// trivial value, with no allocation or reference counting.
    public func load() -> Value {
        storage[kurarin_atomic_load_acquire(index)]
    }
}
