// Minimal atomic counter for the lock-free command queue.
//
// Swift's Synchronization.Atomic requires macOS 15, but process taps put the
// floor at 14.2, so the ordering guarantees come from C11 atomics instead.
// Plain loads and stores would be atomic in practice on the hardware but carry
// no ordering, leaving the compiler free to move the payload write across the
// index publish — which is exactly the reordering the queue depends on not
// happening.

#ifndef KURARIN_ATOMICS_H
#define KURARIN_ATOMICS_H

#include <stdatomic.h>
#include <stddef.h>

typedef struct {
    _Atomic size_t value;
} KurarinAtomicIndex;

static inline void kurarin_atomic_init(KurarinAtomicIndex* index) {
    atomic_store_explicit(&index->value, 0, memory_order_relaxed);
}

/// Acquire: everything the writer published before its release store is
/// visible once this load observes it.
static inline size_t kurarin_atomic_load_acquire(const KurarinAtomicIndex* index) {
    return atomic_load_explicit(&index->value, memory_order_acquire);
}

/// Release: the payload write cannot be reordered after this store.
static inline void kurarin_atomic_store_release(KurarinAtomicIndex* index, size_t newValue) {
    atomic_store_explicit(&index->value, newValue, memory_order_release);
}

/// Orders everything read before it against everything read after it.
///
/// A seqlock reader needs this between copying the payload and re-reading the
/// count. Two acquire loads are not enough: acquire keeps later reads from
/// moving earlier, and says nothing about earlier reads moving later — so the
/// copy is free to drift past the check that is supposed to validate it, and a
/// torn read passes.
static inline void kurarin_atomic_acquire_fence(void) {
    atomic_thread_fence(memory_order_acquire);
}

/// Relaxed: only the owning side reads its own index, so no ordering is needed.
static inline size_t kurarin_atomic_load_relaxed(const KurarinAtomicIndex* index) {
    return atomic_load_explicit(&index->value, memory_order_relaxed);
}

#endif
