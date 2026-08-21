#ifndef KURARIN_ALLOC_PROBE_H
#define KURARIN_ALLOC_PROBE_H

#include <stdint.h>

/// Counts heap traffic on the calling thread, for proving that the audio
/// callback does none.
///
/// The project's hardest rule is that nothing on the audio thread allocates:
/// `malloc` takes a lock, and a render callback that blocks on it drops a
/// buffer. Reading the code is how that rule has been enforced so far, and it
/// has already been broken once by a Swift array literal that looked harmless.
///
/// The counter hangs off `malloc_logger`, the hook Darwin's malloc calls for
/// stack logging. It is called with the malloc lock held, so the callback must
/// not allocate — which is why this is C. A Swift closure here deadlocks or
/// crashes the moment ARC touches anything.
///
/// Counts only the thread that called `begin`, so other threads going about
/// their business do not show up as violations. Test-only, and one region at a
/// time: a second `begin` before `end` only resets the count.
void kurarin_alloc_probe_begin(void);

/// Stops counting and returns how many allocations happened since `begin`.
uint64_t kurarin_alloc_probe_end(void);

/// Whether the probe can see allocations at all on this system. A false here
/// means a test that relies on it is proving nothing and should fail loudly
/// rather than pass silently.
int kurarin_alloc_probe_is_working(void);

#endif
