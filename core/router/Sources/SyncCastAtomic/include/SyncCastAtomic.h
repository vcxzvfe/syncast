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

// A seqlock-published (frame, host-time) pair: the capture IOProc stamps
// every delivered block with the hardware clock, and the LAN producer reads
// the newest stamp from its own thread.
//
// The writer is a real-time audio thread, so it must never block or retry:
// it bumps the sequence to odd, writes the payload, bumps it to even. A
// reader that catches an odd sequence, or a sequence that changed under it,
// simply tries again — the newest stamp is a few milliseconds away anyway.
// Sequence 0 means "nothing published yet", so the first publish lands on 2.
typedef struct {
    _Atomic uint32_t seq;
    _Atomic int64_t frame;
    _Atomic uint64_t host_ns;
} SCAtomicAnchor;

static inline void sc_anchor_init(SCAtomicAnchor *a) {
    atomic_init(&a->seq, 0u);
    atomic_init(&a->frame, (int64_t)0);
    atomic_init(&a->host_ns, (uint64_t)0);
}

static inline void sc_anchor_publish(SCAtomicAnchor *a, int64_t frame, uint64_t host_ns) {
    uint32_t s = atomic_load_explicit(&a->seq, memory_order_relaxed);
    atomic_store_explicit(&a->seq, s + 1u, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&a->frame, frame, memory_order_relaxed);
    atomic_store_explicit(&a->host_ns, host_ns, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&a->seq, s + 2u, memory_order_relaxed);
}

// Returns 1 and fills the outputs when a consistent pair was read, 0 when
// nothing has been published yet or the writer kept moving under us.
static inline int sc_anchor_load(SCAtomicAnchor *a, int64_t *frame, uint64_t *host_ns) {
    for (int attempt = 0; attempt < 8; attempt++) {
        uint32_t s1 = atomic_load_explicit(&a->seq, memory_order_acquire);
        if (s1 == 0u || (s1 & 1u) != 0u) continue;
        int64_t f = atomic_load_explicit(&a->frame, memory_order_relaxed);
        uint64_t h = atomic_load_explicit(&a->host_ns, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        uint32_t s2 = atomic_load_explicit(&a->seq, memory_order_relaxed);
        if (s1 == s2) {
            *frame = f;
            *host_ns = h;
            return 1;
        }
    }
    return 0;
}
