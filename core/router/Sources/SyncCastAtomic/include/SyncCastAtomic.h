#pragma once

#include <stdatomic.h>
#include <stdint.h>

// Lock-free 64-bit atomic counter for the SPSC ring buffer's write cursor.
// We use C11 stdatomic with explicit memory orderings so the producer (the
// real-time CoreAudio IOProc) and consumers (the AUHAL render callbacks
// plus the audio-socket writer) never block each other on a Darwin lock.

typedef struct {
    _Atomic int64_t value;
} SCAtomicInt64;

static inline void sc_atomic_init(SCAtomicInt64 *a, int64_t v) {
    atomic_init(&a->value, v);
}

static inline int64_t sc_atomic_load_acquire(SCAtomicInt64 *a) {
    return atomic_load_explicit(&a->value, memory_order_acquire);
}

static inline void sc_atomic_store_release(SCAtomicInt64 *a, int64_t v) {
    atomic_store_explicit(&a->value, v, memory_order_release);
}

static inline int64_t sc_atomic_fetch_add(SCAtomicInt64 *a, int64_t delta) {
    return atomic_fetch_add_explicit(&a->value, delta, memory_order_acq_rel);
}
