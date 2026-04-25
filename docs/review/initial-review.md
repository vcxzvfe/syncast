# SyncCast Initial Code Review

> Reviewer: Claude Code (claude-sonnet-4-6)  
> Date: 2026-04-25  
> Scope: core/router Swift package, sidecar Python package, docs/ARCHITECTURE.md, ADR-001–006

---

## Findings

---

### 1. [HIGH] RT thread heap allocation in IOProc — `var planar: [UnsafePointer<Float>]`

**File**: `core/router/Sources/SyncCastRouter/Capture.swift:61`

```swift
var planar: [UnsafePointer<Float>] = []
planar.reserveCapacity(chanCount)
```

`[]` creates a Swift `Array` backed by a heap allocation. Even though `reserveCapacity` pre-sizes the buffer, the initial `= []` triggers an `malloc`/`swift_allocObject` before `reserveCapacity` gets to run. In an IOProc body this risks a priority inversion if the allocator takes a lock held by a normal-priority thread (which is precisely what `malloc` does on Darwin). The comment on line 9 explicitly prohibits allocations here.

**Fix**: Allocate a fixed-size stack buffer or pre-allocate `planar` once during `start()` and write it as a stored `UnsafePointer<Float>?` pair on `Capture`, not inside the closure. For 2-channel stereo the channel count is a compile-time constant; a two-element tuple or a small `ContiguousArray` allocated during `start()` and captured by value as a fixed array suffices:

```swift
// Allocated once in start(), before the IOProc is registered.
var ch0: UnsafePointer<Float>?
var ch1: UnsafePointer<Float>?
// Inside the IOProc:
ch0 = inputList[0].mData?.assumingMemoryBound(to: Float.self)
ch1 = inputList[1].mData?.assumingMemoryBound(to: Float.self)
if let p0 = ch0, let p1 = ch1 {
    ringRef.write(channels: (p0, p1), frames: frames)
}
```

---

### 2. [HIGH] `OSAllocatedUnfairLock` inside the IOProc — priority inversion exposure

**File**: `core/router/Sources/SyncCastRouter/RingBuffer.swift:51`  
**File**: `core/router/Sources/SyncCastRouter/Capture.swift:70` (via `ringRef.write`)

`RingBuffer.write` calls `writeLock.withLock { ... }`. `OSAllocatedUnfairLock` is a Darwin `os_unfair_lock`, which is non-fair and non-sleeping. The documentation says "unfair lock must not be used by realtime threads" — the concern is not sleeping per se but that a non-real-time thread holding the lock can be pre-empted, causing the real-time IOProc to spin-wait inside the lock and miss its deadline.

ADR-001 and the source comment both claim the lock is "bounded-wait and acceptable here." That is incorrect for an OS-scheduled unfair lock when the competing thread is a regular QoS thread. The bounded-wait claim applies only if both competing threads are real-time.

**Fix**: Replace the write-side lock with a true lock-free approach. The ring is described as SPSC from the write side — with only one producer (the IOProc) you can eliminate the write lock entirely. Make `writeCursor` an `_Atomic` / `Atomic<Int64>` and publish it with a `release` memory order after the copy. Readers acquire it with `acquire` order. No lock is needed at all for a single-producer ring.

---

### 3. [HIGH] `RingBuffer.read` is O(frames) with a per-sample loop — AUHAL render thread budget violation

**File**: `core/router/Sources/SyncCastRouter/RingBuffer.swift:81–94`

```swift
for f in 0..<frames {
    let abs = startFrame &+ Int64(f)
    if abs >= lowerValid && abs < upperValid {
        let idx = Int(abs & Int64(cap - 1))
        for ch in 0..<channelCount {
            out[ch][f] = storage[ch][idx]
        }
    } else { ... }
}
```

With 512-frame AUHAL buffers this runs 512 × 2 = 1024 iterations with a branch and two memory dereferences per iteration. The contiguous case (no wrap, all frames valid) could be reduced to two `memcpy` calls (one per channel), each handling up to `cap - start` frames before a wrap. Per-sample branches also inhibit auto-vectorization.

**Fix**: Mirror the split-chunk write path already used in `write()`:

```swift
let start = Int(startFrame & Int64(cap - 1))
let firstChunk = min(frames, cap - start)
for ch in 0..<channelCount {
    out[ch].update(from: storage[ch].advanced(by: start), count: firstChunk)
    if frames > firstChunk {
        out[ch].advanced(by: firstChunk).update(from: storage[ch], count: frames - firstChunk)
    }
}
```

Zero-fill the out-of-window frames separately only when `lowerValid > startFrame`.

---

### 4. [HIGH] `LocalOutput.render` holds `stateLock` then immediately takes `ring.writePosition` — nested lock ordering not documented

**File**: `core/router/Sources/SyncCastRouter/LocalOutput.swift:159–163`

```swift
let snapshot = stateLock.withLock {
    (gain: _gain, muted: _muted, backoff: _readBackoffFrames, cursor: _readCursor)
}
let writePos = ring.writePosition  // acquires writeLock inside RingBuffer
```

The render callback takes `stateLock` then immediately accesses `ring.writePosition`, which acquires `writeLock`. On the capture side, the IOProc holds `writeLock` and never takes `stateLock`. So the ordering is `stateLock → writeLock` in render and `writeLock` alone in capture. This is not a deadlock today, but the absence of a documented lock order makes it fragile. More importantly, the snapshot + `ring.writePosition` read is not atomic: a write can land between the two acquires, meaning `snapshot.cursor` is stale relative to the `writePos` read, which can produce a slightly wrong `startFrame`. This is a correctness issue for tight-latency scenarios.

**Fix**: Either expose a combined `readPositionAndWritePosition` on `RingBuffer` under a single lock, or (preferred) move to the lock-free design from finding #2 so `writePosition` is a simple atomic load with no lock at all.

---

### 5. [HIGH] `writeAll` is called from inside `withCheckedThrowingContinuation` — blocking I/O on the Swift concurrency cooperative thread

**File**: `core/router/Sources/SyncCastRouter/IpcClient.swift:78–87`

```swift
return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
    self.pending[id] = cont
    do {
        try writeAll(line)  // blocking syscall!
    } catch { ... }
}
```

`writeAll` calls `Darwin.write` in a loop inside the continuation body, which is still running on the Swift concurrency cooperative pool thread. A blocking write will occupy the thread for the duration of the kernel call. For a local Unix socket that's almost always fast, but under load (or if the socket buffer is full) it can block the cooperative pool thread, starving other `async` tasks.

**Fix**: Move `writeAll` outside the continuation or run it in a detached `Task` on a background executor:

```swift
let id = nextID; nextID += 1
// write the bytes before suspending
try writeAll(line)
return try await withCheckedThrowingContinuation { cont in
    self.pending[id] = cont
}
```

If write fails, throw before installing the continuation. This is simpler and avoids blocking the pool thread.

---

### 6. [MEDIUM] `readLoop` calls `Darwin.read` synchronously on the Swift concurrency cooperative thread

**File**: `core/router/Sources/SyncCastRouter/IpcClient.swift:110–113`

```swift
let n = tmp.withUnsafeMutableBytes { rawPtr -> Int in
    let p = rawPtr.baseAddress!
    return Darwin.read(fd, p, chunkSize)
}
```

Same class of problem as finding #5. `Darwin.read` on a blocking socket will block the cooperative thread. The socket is never set to `O_NONBLOCK` and there is no `select`/`poll` before reading.

**Fix**: Use `O_NONBLOCK` on the socket and integrate it with Swift concurrency via `AsyncStream` + a `DispatchSource.makeReadSource`, or move the read loop to a dedicated POSIX thread (`Thread`) that calls `loop.call_soon_threadsafe` into an asyncio-style callback on the actor (similar to what the Python side does in `AudioSocketReader`).

---

### 7. [MEDIUM] `IpcClient.connect` leaks the socket fd on a race condition

**File**: `core/router/Sources/SyncCastRouter/IpcClient.swift:31–58`

If `connect()` succeeds but `self.fd = s` is never reached (e.g., the actor suspends between the `Darwin.connect` call and the assignment, then `close()` is called from another caller), `s` is leaked. More concretely, if `connect()` is called concurrently by two callers (possible since actor re-entrancy allows suspension), the second caller will overwrite `self.fd` with the new socket before the old one is closed.

**Fix**: Add a guard at the top:

```swift
guard fd < 0 else { return }  // already connected
```

And close `s` before throwing in every error path (the `connectRC != 0` branch already does this, but document it explicitly).

---

### 8. [MEDIUM] `sockaddr_un.sun_path` size check uses `pathCapacity - 1` but `strlen(src)` can return `pathCapacity - 1` leaving no room for null terminator after `memcpy`

**File**: `core/router/Sources/SyncCastRouter/IpcClient.swift:40–44`

```swift
let count = min(strlen(src), pathCapacity - 1)
memcpy(dstPtr, src, count)
dstPtr[count] = 0
```

`pathCapacity` is `MemoryLayout.size(ofValue: addr.sun_path)` = 104 bytes on macOS. `strlen` returns the number of non-null bytes. `min(strlen(src), 103)` allows at most 103 bytes to be copied, then `dstPtr[103] = 0`. Index 103 is the last valid byte of a 104-byte buffer — this is correct. However, the `connect` call passes `socklen_t(MemoryLayout<sockaddr_un>.size)` (106 bytes) as the length, which includes 2 bytes of `sun_len` + `sun_family`. The sun_path field starts at offset 2, so passing the full struct size is correct. This is borderline: the code is technically safe, but should add an explicit runtime assertion:

```swift
precondition(strlen(src) < pathCapacity, "Unix socket path too long: \(path)")
```

---

### 9. [MEDIUM] `server.py` calls `os.chmod` after `asyncio.start_unix_server` — TOCTOU window where socket is world-readable

**File**: `sidecar/src/syncast_sidecar/server.py:46–49`

```python
self._server = await asyncio.start_unix_server(
    self._on_client, path=str(self._control_path),
)
os.chmod(self._control_path, 0o600)
```

`asyncio.start_unix_server` creates the socket with the process umask as permissions. Between socket creation and `chmod`, any local user can connect. Even if the connection is then rejected, this is a non-trivial race on a multi-user system.

**Fix**: Create the socket file manually with the desired permissions before passing it to `asyncio.start_unix_server`:

```python
# Pre-create the socket path with restricted permissions.
old_umask = os.umask(0o177)  # 0o600 = 0o777 & ~0o177
try:
    self._server = await asyncio.start_unix_server(
        self._on_client, path=str(self._control_path),
    )
finally:
    os.umask(old_umask)
```

The `audio_socket.py` path does this correctly via `os.chmod` immediately after `s.bind` on the same thread (no async gap) — apply the same pattern here.

---

### 10. [MEDIUM] `owntone_backend.py` `_wait_for_rest` calls blocking `urllib` I/O from inside an `async` function on the event loop thread

**File**: `sidecar/src/syncast_sidecar/owntone_backend.py:187–197`

```python
async def _wait_for_rest(self, timeout_s: float) -> None:
    ...
    while time.monotonic() < deadline:
        try:
            self._get("/api/config")   # blocking urllib call on event loop thread!
```

`self._get` calls `urlrequest.urlopen(req, timeout=2.0)`, which is a synchronous blocking I/O call. Calling it directly from the `async` body blocks the asyncio event loop for up to 2 s per iteration. During a 10-second timeout window that means the event loop can be stalled for up to 10 s, blocking all other tasks including the control socket.

**Fix**: Use `loop.run_in_executor(None, self._get, "/api/config")` to run the blocking call on the thread pool:

```python
loop = asyncio.get_running_loop()
await loop.run_in_executor(None, self._get, "/api/config")
```

All `_get`/`_put`/`_post` calls from async context need the same treatment.

---

### 11. [MEDIUM] `owntone_backend.py` REST methods called from `async` context without executor wrapping

**File**: `sidecar/src/syncast_sidecar/owntone_backend.py:131–150`

`list_outputs()`, `set_output_enabled()`, `set_output_volume()`, `play_pipe()`, and `flush()` all call synchronous `urllib` under the hood. These are invoked from `DeviceManager` methods that run on the asyncio thread (e.g., `start_stream`, `stop_stream`). Same blocking problem as finding #10.

**Fix**: Either make `OwnToneBackend` an `async` class with `run_in_executor` wrappers for every REST call, or use an async HTTP client (`aiohttp`, `httpx`) instead of `urllib`.

---

### 12. [MEDIUM] `audio_socket.py` `_sink` (i.e., `OwnToneBackend.write_pcm`) called from a worker thread — no thread-safety guarantee on `_fifo_fd`

**File**: `sidecar/src/syncast_sidecar/audio_socket.py:105`  
**File**: `sidecar/src/syncast_sidecar/owntone_backend.py:115–127`

`AudioSocketReader._run` calls `self._sink(data)` from a `threading.Thread`. The sink is `OwnToneBackend.write_pcm`, which reads `self._fifo_fd` without a lock. `_fifo_fd` can be written to `None` by `stop()` (called from the asyncio thread) concurrently. On CPython the GIL makes this safe in practice, but the code relies on an implicit invariant:

- `stop()` sets `self._fifo_fd = None` before `os.close(fd)`.
- `write_pcm` reads `_fifo_fd` then calls `os.write(_fifo_fd, ...)`.

Between the read and the `os.write`, `stop()` could close the fd, and a third party could reuse the fd number. `os.write` would then write to the wrong file descriptor. This is a classic use-after-close race.

**Fix**: Take a local snapshot under a threading lock:

```python
def write_pcm(self, data: bytes) -> int:
    fd = self._fifo_fd   # one atomic read under GIL
    if fd is None:
        return 0
    try:
        return os.write(fd, data)
    except (BlockingIOError, BrokenPipeError, OSError) as e:
        ...
```

This is already close to what the code does, but the `None`-check and the `os.write` use the same local `fd` reference, so the snapshot pattern works here. What is actually needed is to move the `self._fifo_fd = None` assignment in `stop()` to happen *after* `os.close(fd)` has returned, not before. Currently:

```python
os.close(self._fifo_fd)
self._fifo_fd = None     # ← should be before close, not after, to prevent double-close
```

It is before close in the actual code (line 97: `os.close` then line 98: `= None`), which is the right order. The residual risk is the fd reuse window between read and `os.write`. Snapshotting the fd into a local solves it:

```python
def write_pcm(self, data: bytes) -> int:
    fd = self._fifo_fd
    if fd is None:
        return 0
    ...
    return os.write(fd, data)
```

---

### 13. [MEDIUM] `DeviceManager.remove` pops from `_devices` outside the lock, then calls async stop/disconnect

**File**: `sidecar/src/syncast_sidecar/device_manager.py:136–148`

```python
async def remove(self, device_id: str) -> dict[str, Any]:
    async with self._lock:
        dev = self._devices.pop(device_id, None)
    if dev is None: ...
    try:
        await dev.streamer.stop()    # ← outside the lock
    ...
    await dev.streamer.disconnect()  # ← outside the lock
```

`stop()` and `disconnect()` on the streamer are called after the lock is released. If `start_stream` runs concurrently, it could observe a state where the device is not in `_devices` but the streamer is still in a partially stopped state, leading to incorrect `event.device_state` notifications or a use-after-stop on the streamer.

**Fix**: Move the `stop` + `disconnect` calls inside the lock, or at minimum document the invariant that `stop` and `disconnect` are idempotent and concurrency-safe on `AirPlay2Streamer`.

---

### 14. [MEDIUM] `Scheduler.plan` ignores the manual trim direction — `trim` can make the fast path faster than its own hardware latency

**File**: `core/router/Sources/SyncCastRouter/Scheduler.swift:58`

```swift
let backoffMs = max(0, master - dev.measuredMs + trim)
```

`trim` is `manualTrimMs[dev.deviceID] ?? 0`, read from `DeviceRouting.manualDelayMs` which is signed and ranges `−2000…+2000` ms. A positive trim adds more delay (device plays later), which is safe. A *negative* trim reduces the backoff, which is fine as long as `backoffMs` doesn't go below zero. The `max(0, ...)` clamp prevents negative backoff, so the device would end up with zero delay — it plays at the earliest possible time. This is likely the intended semantics ("never play *ahead* of the write cursor").

The subtlety: `DeviceRouting.manualDelayMs` is documented as user-overridable trim (`±2000 ms`) but the IPC schema says `stream.start.anchor_time_ns` is the alignment anchor. There is no cap preventing a user from setting `manualDelayMs = -2000` and receiving silence (because the cursor is at zero backoff while the writer is 1.8 s ahead). This should be validated at the UI layer or clamped to `max(−(T_master − L_i), ...)` to prevent silence.

**Fix**: Add a validation step in `Scheduler.plan` or in `Router.setRouting` that clamps trim to `[-(master - dev.measuredMs), safetyMarginMs]`.

---

### 15. [MEDIUM] `Clock.nowNs()` uses integer overflow arithmetic with potentially zero `denom`

**File**: `core/router/Sources/SyncCastRouter/Clock.swift:18`

```swift
return raw &* UInt64(info.numer) / UInt64(info.denom)
```

`mach_timebase_info` can return `denom = 0` on a misconfigured or virtual machine. Division by zero on `UInt64` is a trap (crash). On real Apple hardware `numer == denom == 1` (ARM) or `numer/denom ≈ 125/3` (Intel), but a defensive check costs nothing:

```swift
guard info.denom != 0 else { return raw }
```

---

### 16. [MEDIUM] `AirPlay2Streamer._stream_loop` is a placeholder that does nothing — streaming silently produces no audio

**File**: `sidecar/src/syncast_sidecar/airplay2.py:153–165`

`_stream_loop` logs a message and then sleeps forever. The `AudioSocketReader` in `audio_socket.py` correctly receives PCM packets and calls the FIFO sink, but `AirPlay2Streamer` is never wired to OwnTone. ADR-006 describes OwnTone as the streaming backend, but `device_manager.py` still creates `AirPlay2Streamer` instances (not an OwnTone-backed streamer) for every `device.add` call.

The `StreamerProtocol` abstraction in `device_manager.py` is well-designed, but no concrete implementation that connects `AirPlay2Streamer.start()` → `AudioSocketReader` → `OwnToneBackend.write_pcm` → FIFO → OwnTone exists yet. The architecture intends this wiring; the code just has not caught up with ADR-006.

**Fix**: Implement the `StreamerProtocol` on `OwnToneBackend` (or create a `OwnToneStreamer` adapter class), wire it into `DeviceManager.add`, and remove the placeholder sleep loop from `AirPlay2Streamer`. Until this is done, streaming is silently broken — the `stream.start` RPC returns `{"started": True}` while no audio actually flows.

---

### 17. [LOW] `Capture.start()` is not thread-safe — `running` and `ioProcID` are read/written from two threads

**File**: `core/router/Sources/SyncCastRouter/Capture.swift:41–91`

`start()` and `stop()` write `running` and `ioProcID`. Both can be called from the `Router` actor's context (Swift concurrency), but `Capture` itself is a non-isolated `final class`, not an actor. `deinit` calls `stop()` from the deallocating thread. If an actor method holds a reference to `Capture` and calls `stop()` while `deinit` fires (possible if the actor method suspends), both paths race on `running`. This is low-risk in practice because the `Router` actor serializes calls, but `Capture` should be marked `@MainActor`-isolated or converted to an `actor` for clarity.

---

### 18. [LOW] `LocalOutput.start()` is not guarded against re-entrant calls across actor suspension points

**File**: `core/router/Sources/SyncCastRouter/LocalOutput.swift:60–61`

```swift
public func start() throws {
    guard !initialized else { return }
```

`initialized` is read without holding `stateLock`. Two concurrent calls could both see `initialized == false` and both create an `AudioUnit`. Same class of issue as finding #17.

---

### 19. [LOW] `server.py` `_handle_line` sends error responses when `req_id` is `None` — violates JSON-RPC 2.0 spec

**File**: `sidecar/src/syncast_sidecar/server.py:122–127`

```python
except jsonrpc.RpcError as e:
    writer.write(jsonrpc.encode_error(req_id, e))
```

When `parse_request` raises before extracting `req_id`, `req_id` is `None`. JSON-RPC 2.0 §6 states: "If there was an error in detecting the id in the Request object (e.g. Parse error/Invalid Request), it MUST be Null." This is actually fine for notifications, but for batch or unknown format errors the Swift client (`handleLine`) tries to cast `obj["id"]` as `Int`, so a response with `"id": null` is silently dropped (no continuation is resumed). The client therefore hangs waiting for a reply that will never be matched.

This is only reachable if the Swift side sends malformed JSON, which should not happen in normal operation. However, the client should handle `"id": null` error responses defensively. A simpler fix is to log the error server-side and close the connection on a parse failure, since the protocol is broken at that point.

---

### 20. [LOW] `owntone_backend.py` `_write_config` generates a config with `uid = "<string>"` but OwnTone expects a numeric UID

**File**: `sidecar/src/syncast_sidecar/owntone_backend.py:163`

```python
uid = "{os.getuid()}"
```

This is fine — `os.getuid()` returns an integer and Python's f-string will emit it as a decimal number, e.g. `uid = "501"`. OwnTone's config parser accepts this. However, the surrounding text template uses `"""..."""` triple-quote and the indentation structure is non-standard for OwnTone's config format. OwnTone uses `forked-daapd.conf`-style config with `{ }` blocks. The generated config here omits several mandatory sections (most notably `mpd {}` and `library { }` must have proper port entries) and the `library.port` field conflicts with the REST port. Verify against OwnTone's actual config schema — a malformed config will cause silent startup failure caught only in `_wait_for_rest`.

---

### 21. [LOW] Architecture/ADR drift — `ARCHITECTURE.md` still describes pyatv as the AirPlay streaming backend

**File**: `docs/ARCHITECTURE.md:§2 (top-level diagram), §3 (module map), §4 (audio data path), §6 (concurrency model)`

The architecture document shows "pyatv ▶ AirPlay 2 RTSP" and "IPC bridge ▶ pyatv sidecar" throughout. ADR-006 (accepted 2026-04-25) supersedes this: the streaming backend is now OwnTone, with pyatv retained for discovery only. The architecture diagram and module map need to be updated to reflect OwnTone as the streaming layer and the FIFO audio path.

**Fix**: Update `ARCHITECTURE.md` §2, §3, §4, and §6 to describe OwnTone as the audio emitter. Add the FIFO boundary to the data path diagram.

---

### 22. [LOW] `scan_airplay2` protocol detection heuristic is fragile

**File**: `sidecar/src/syncast_sidecar/airplay2.py:43–49`

```python
is_airplay2 = any(
    getattr(s, "protocol", None).__class__.__name__ == "Protocol"
    and "airplay" in str(getattr(s, "protocol", "")).lower()
    for s in services
)
```

This checks that the class name is `"Protocol"` (the pyatv enum class) and that its string representation contains "airplay". This is brittle: pyatv could rename the class or change the `__str__` output in a minor version without a breaking API change. The correct way is to import and compare against `pyatv.const.Protocol.AirPlay`:

```python
from pyatv.const import Protocol
is_airplay2 = any(getattr(s, "protocol", None) == Protocol.AirPlay for s in services)
```

---

## Review Summary

| Severity | Count | Status  |
|----------|-------|---------|
| CRITICAL | 0     | pass    |
| HIGH     | 5     | warn    |
| MEDIUM   | 9     | warn    |
| LOW      | 8     | note    |

**Verdict: WARNING — 5 HIGH issues must be resolved before the audio engine is considered production-ready. The two most urgent are the IOProc heap allocation (#1) and the unfair lock in the IOProc write path (#2), both of which risk real-time deadline misses under normal OS load. The blocking I/O on Swift concurrency cooperative threads (#5, #6) will cause task starvation under any socket backpressure. The missing OwnTone wiring (#16) means streaming produces no audio despite returning success, which should be treated as a P0 correctness blocker even in a pre-release scaffold.**
