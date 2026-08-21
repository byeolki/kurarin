#include "include/KurarinAllocProbe.h"

#include <pthread.h>
#include <stdlib.h>

/// Darwin calls this for every heap operation when it is non-null. Declared
/// rather than included because the header that carries it is private.
typedef void (*malloc_logger_t)(uint32_t type,
                                uintptr_t arg1,
                                uintptr_t arg2,
                                uintptr_t arg3,
                                uintptr_t result,
                                uint32_t backtrace_to_skip);

extern malloc_logger_t malloc_logger;

/// Bit set by malloc, calloc, realloc and friends. Frees carry a different
/// bit, and counting those too would report a unit that only releases memory
/// as if it had claimed some.
#define MALLOC_LOG_TYPE_ALLOCATE 2

static volatile uint64_t observed = 0;
static volatile size_t probe_size = 4096;
static malloc_logger_t previous = NULL;
static pthread_t watched;
static int active = 0;

static void count(uint32_t type,
                  uintptr_t arg1,
                  uintptr_t arg2,
                  uintptr_t arg3,
                  uintptr_t result,
                  uint32_t backtrace_to_skip) {
    (void)arg1; (void)arg2; (void)arg3; (void)result; (void)backtrace_to_skip;
    // Nothing here may allocate: malloc holds its lock across this call.
    // pthread_self and pthread_equal are both safe on that count.
    //
    // Only the thread being watched counts. The hook is process-wide, and a
    // test runner has threads of its own that allocate whenever they feel
    // like it — counting those would make the result depend on what else the
    // machine was doing.
    if (!pthread_equal(pthread_self(), watched)) {
        return;
    }
    if (type & MALLOC_LOG_TYPE_ALLOCATE) {
        observed++;
    }
}

void kurarin_alloc_probe_begin(void) {
    if (active) {
        // Saving the hook again would save this counter over the real
        // previous one, and ending would then install an endless loop.
        observed = 0;
        return;
    }
    observed = 0;
    watched = pthread_self();
    previous = malloc_logger;
    malloc_logger = count;
    active = 1;
}

uint64_t kurarin_alloc_probe_end(void) {
    if (!active) {
        return 0;
    }
    malloc_logger = previous;
    previous = NULL;
    active = 0;
    return observed;
}

int kurarin_alloc_probe_is_working(void) {
    kurarin_alloc_probe_begin();
    // The size comes from a volatile so the compiler cannot fold it, and the
    // barrier makes the pointer escape. Without both, an optimising build
    // deletes the malloc/free pair outright and the probe reports itself
    // broken when it is not — which is exactly what happened the first time.
    void *block = malloc(probe_size);
    __asm__ volatile("" : : "r"(block) : "memory");
    free(block);
    uint64_t seen = kurarin_alloc_probe_end();
    return seen > 0;
}
