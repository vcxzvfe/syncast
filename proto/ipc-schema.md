# SyncCast IPC Protocol

Swift router (parent) ↔ Python AirPlay 2 sidecar (child).

- **Transport**: Unix domain socket at `$XDG_RUNTIME_DIR/syncast.sock` (fallback: `/tmp/syncast-$UID.sock`).
- **Wire format**: newline-delimited JSON-RPC 2.0. One JSON object per line.
- **Lifecycle**: Swift router spawns sidecar as a child process, owns the socket fd, and forwards SIGTERM on shutdown.
- **Audio data**: separate `AF_UNIX SOCK_SEQPACKET` audio socket carrying raw 16-bit signed little-endian PCM @ 48 kHz stereo, frame size 480 samples (10 ms). Control channel carries metadata only.

## Versioning

Every request includes `"v": 1`. Sidecar rejects unknown major versions with JSON-RPC error `-32099`.

## Methods (control channel)

### `sidecar.hello`

Handshake. First message after socket connect.

Request:
```json
{"jsonrpc":"2.0","id":1,"method":"sidecar.hello","params":{"v":1,"router_pid":12345}}
```

Response:
```json
{"jsonrpc":"2.0","id":1,"result":{"v":1,"sidecar_version":"0.1.0","pyatv_version":"0.16.1","capabilities":["airplay2.stream","airplay2.multi_target","airplay2.volume","airplay2.metadata"]}}
```

### `discovery.scan`

Trigger an mDNS scan for AirPlay 2 receivers. Returns immediately; results arrive as `event.device_found` notifications.

Request:
```json
{"jsonrpc":"2.0","id":2,"method":"discovery.scan","params":{"timeout_ms":3000}}
```

Response: `{"result":{"scan_id":"<uuid>"}}`.

### `device.add`

Connect to an AirPlay 2 receiver and prepare it for streaming.

```json
{"method":"device.add","params":{
  "device_id":"<stable-uuid-assigned-by-router>",
  "transport":"airplay2",
  "host":"192.168.1.42",
  "port":7000,
  "name":"Xiaomi Sound",
  "credentials":null
}}
```

Result: `{"connected":true,"reported_latency_ms":1820}`.

### `device.remove`

Disconnect.

```json
{"method":"device.remove","params":{"device_id":"..."}}
```

### `device.set_volume`

```json
{"method":"device.set_volume","params":{"device_id":"...","volume":0.65}}
```

`volume` is `0.0`–`1.0`, linear.

### `stream.start`

Begin streaming. Audio frames arrive on the audio socket; control channel receives `event.stream_state` notifications.

```json
{"method":"stream.start","params":{
  "device_ids":["uuid1","uuid2"],
  "anchor_time_ns":17239847239847,
  "sample_rate":48000,
  "channels":2,
  "format":"pcm_s16le"
}}
```

`anchor_time_ns` is the wall-clock target (CLOCK_MONOTONIC_RAW) at which the first audio frame should be heard on the receivers — sidecar uses this to derive the AirPlay 2 RTSP anchor.

### `stream.stop`

```json
{"method":"stream.stop","params":{}}
```

### `stream.flush`

Drop in-flight frames immediately (used for track changes / scrubbing).

### `mode.set`

Switch the data plane between **stereo** mode (legacy: capture audio →
sidecar → AirPlay receivers only) and **whole-home AirPlay** mode
(Strategy 1: bundled OwnTone produces PCM into a fifo broadcast socket
so local CoreAudio outputs ride OwnTone's player clock alongside AirPlay
receivers).

Request:
```json
{"method":"mode.set","params":{"mode":"stereo"}}
```
or
```json
{"method":"mode.set","params":{"mode":"whole_home"}}
```

Response: `{"applied": <bool>, "mode": "stereo|whole_home"}`. `applied`
is `false` if we were already in the requested mode (idempotent).

Side effects:
- `stereo`     — closes the local-fifo broadcast listener if running.
                 OwnTone is left untouched (legacy AirPlay-only flows
                 continue to work).
- `whole_home` — ensures OwnTone is running, opens the broadcast
                 listener at the path returned by `local_fifo.path`.

### `local_fifo.path`

Return the broadcast Unix socket path that Swift `LocalAirPlayBridge`
instances connect to in whole-home mode. Synchronous (no I/O).

Request:
```json
{"method":"local_fifo.path","params":{}}
```

Response: `{"socket_path":"/tmp/syncast-501.localfifo.sock"}` (the UID
substitution makes the path session-unique).

### `local_fifo.diagnostics`

Return broadcast-plane diagnostic counters. Safe to call any time.

Response:
```json
{
  "running": true,
  "mode": "whole_home",
  "bytes_broadcast": 1234567,
  "chunks_broadcast": 880,
  "clients_connected": 2,
  "fifo_open_failures": 0,
  "per_client": [
    {"addr": "...", "chunks_dropped": 0},
    {"addr": "...", "chunks_dropped": 3}
  ]
}
```

When the broadcaster is not running (stereo mode) every counter is
zero and `running` is `false`.

## Broadcast socket (whole-home mode)

In whole-home mode the sidecar opens a SECOND audio socket (in addition
to the inbound one in §"Audio data" above):

- **Path**: returned by `local_fifo.path` — typically
  `/tmp/syncast-$UID.localfifo.sock`.
- **Type**: `AF_UNIX` `SOCK_STREAM`, multi-listen (`listen(8)`). Each
  Swift `LocalAirPlayBridge` connects independently.
- **Direction**: sidecar → bridge (one way; bridges never write back).
- **Format**: raw 16-bit signed little-endian PCM, **44.1 kHz stereo**
  (matches OwnTone's hardcoded fifo output format —
  `owntone-server/src/outputs/fifo.c:64`).
- **Framing**: 1408 bytes per packet (352 frames × 2ch × 2B), one
  `send()` per packet. Mirrors OwnTone's internal packet boundary.
- **Backpressure**: per-client. Sidecar sets a small `SO_SNDBUF` on each
  connection; if a slow consumer's buffer fills, the sidecar drops that
  packet for that client only (and bumps `chunks_dropped` for the
  client). Other clients are unaffected.

## Events (notifications, sidecar → router)

### `event.device_found`

```json
{"method":"event.device_found","params":{
  "scan_id":"...",
  "host":"...","port":7000,"name":"...","model":"AudioAccessory6,1",
  "features":1234567,"requires_password":false
}}
```

### `event.device_state`

```json
{"method":"event.device_state","params":{
  "device_id":"...","state":"connected|streaming|degraded|disconnected",
  "rtt_ms":3.2,"buffer_ms":1820,"last_error":null
}}
```

Emitted at most once per second per device.

### `event.measured_latency`

```json
{"method":"event.measured_latency","params":{
  "device_id":"...","measured_ms":1843,"jitter_ms":4
}}
```

Used by router's scheduler to pad the local-output delay buffer.

### `event.error`

```json
{"method":"event.error","params":{
  "device_id":"...","code":"AIRPLAY_AUTH_FAILED|NETWORK_LOST|...","message":"..."}}
```

## Error codes (JSON-RPC `error.code`)

| Code | Meaning |
|---|---|
| -32700 | Parse error (malformed JSON) |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
| -32000 | Device not found |
| -32001 | Device not connected |
| -32002 | Stream not active |
| -32003 | Capability not supported by this receiver |
| -32099 | Protocol version mismatch |

## Threading model

- Sidecar runs an asyncio event loop on the main thread.
- Audio socket is read on a dedicated thread that pushes frames into a per-device asyncio queue via `loop.call_soon_threadsafe`.
- Each AirPlay receiver gets its own pyatv stream coroutine.
- Backpressure: if any per-device queue exceeds 4×buffer_ms of frames, drop oldest and emit `event.error` with code `BACKPRESSURE_DROP`.

## Future extensions

- `transport: "snapcast"` — snapcast-server backend for non-AirPlay receivers
- `transport: "rtp"` — generic RTP for Linux receivers
- `device.calibrate` — runtime per-device delay measurement
