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
{"jsonrpc":"2.0","id":1,"result":{
  "v":1,
  "sidecar_version":"0.1.0",
  "pyatv_version":"0.16.1",
  "capabilities":["airplay2.stream","airplay2.multi_target","airplay2.volume",
                  "airplay2.metadata","whole_home.local_fifo","airplay2.pairing"]
}}
```

`whole_home.local_fifo` advertises the direction-B local leg: OwnTone renders
the local speakers as a `fifo` output on its own player clock, which the
sidecar's `LocalFifoBroadcaster` reads and fans to the Swift bridge — so the
local speakers share OwnTone's timeline with the remote AirPlay outputs with
no self-target and no PIN.

`airplay2.pairing` advertises the interactive pairing methods below, so the
menubar can gate its pairing UI on a capability rather than probing for a
method.

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
  "airplay_device_id":"02AB00CD00EF"
}}
```

Result: `{"connected":true,"reported_latency_ms":1820}`.

`airplay_device_id` is the receiver's Bonjour TXT `deviceid`, normalised to
colon-free uppercase hex. It is the ONLY stable identity an AirPlay endpoint
exposes, and OwnTone derives its own output id from exactly this value
(`int("0200CAFE0001", 16) == 2202428899329`, which is that speaker's row in
OwnTone's database). The sidecar matches devices to OwnTone outputs by this id
first and falls back to the display name only when it is absent — names
collide in practice, and a collision routes audio to the wrong machine.
Optional, for endpoints whose TXT record omits it.

The previously documented `credentials` field is REMOVED. Neither side ever
implemented it, and credentials do not belong on this call: pairing is an
interactive flow (see `pairing.*`) and the resulting credential never crosses
this wire in either direction.

Where the credential actually lives: OwnTone's own `speakers.auth_key` column
in `songs.db`, in cleartext, and nowhere else. There is no second copy. The
sidecar keeps that directory owner-only (0700, with the database 0600) because
that file permission is the whole of its protection. A rebuilt or deleted
`songs.db` therefore means re-pairing, full-screen PIN and all — do not
describe it as recoverable until something actually re-injects the key.

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

### `sync.airplay_offset`

Read the Layer-3 residual-offset state. No side effects.

Whole-home sync is layered:

1. **Layer 1** — broadcaster delay, held at 0. OwnTone's fifo output
   module already releases each byte at
   `pts + outputs_buffer_duration_ms + offset_ms`, so adding a
   broadcaster delay on top would double-count.
2. **Layer 2** — the PI loop in Swift's `LocalAirPlayBridge` slaves the
   local device clock to OwnTone's fifo write rate, so the two legs
   never drift apart.
3. **Layer 3** — this. What is left after 1 and 2 is a FIXED residual:
   the local leg's own pipeline latency `L_local` (ring fill + AUHAL
   render quantum + packet quantisation + the CoreAudio device's
   presentation latency). The local leg cannot be advanced — the pipe
   cannot surrender a byte before OwnTone releases it — so the AirPlay
   leg is DELAYED by `L_local` instead, via OwnTone's per-output
   `offset_ms`.

Response:
```json
{
  "offset_ms": 132,
  "effective_offset_ms": 132,
  "source": "router_measured",
  "mode": "whole_home",
  "min_offset_ms": -2000,
  "max_offset_ms": 2000,
  "default_offset_ms": 130,
  "applied": {"2933476098287": 132},
  "latched": {"2933476098287": 132},
  "write_failures": []
}
```

- `offset_ms` — the configured value.
- `effective_offset_ms` — the value the sidecar INTENDS outputs to
  carry. Always 0 in stereo mode: there is no fifo→bridge chain there,
  so there is no `L_local` to cancel. This is intent, not truth — see
  `latched`.
- `source` — `default`, `router_measured`, or `manual`.
- `applied` — OwnTone output id → offset this process last wrote to its
  database row.
- `latched` — OwnTone output id → offset a LIVE session is known to be
  carrying. Narrower than `applied` on purpose: OwnTone copies the
  offset when it builds an output session and refuses to change a
  playing one, so an output that was ALREADY selected when we wrote its
  row is absent here even though the write succeeded. Absence means
  "unknown", and every consumer must read that as "must be re-latched",
  never as "already correct". This is what the router seeds its
  no-op-detection deadband from; seeding from `effective_offset_ms`
  instead let a receiver that was live before whole-home started run
  ~`L_local` ahead of the local leg for a whole session.
- `write_failures` — output ids whose offset write failed. Their
  persisted row is whatever an earlier session left, so they are still
  visited by the rollback sweep, and their presence invalidates any
  seed derived from `latched`.

### `sync.set_airplay_offset_ms`

Set how far the AirPlay leg is delayed to meet the local leg.

Request:
```json
{"method":"sync.set_airplay_offset_ms",
 "params":{"offset_ms":132,"source":"router_measured","relatch":true}}
```

- `offset_ms` (required, number) — `L_local` in milliseconds. POSITIVE
  delays the AirPlay leg; `0` retires the correction entirely. Clamped
  to OwnTone's own accepted range (±2000 ms, `player.c:2930`) so the
  call can never produce an opaque REST 400.
- `source` (optional) — `router_measured` or `manual`. Defaults to
  `manual`.
- `relatch` (optional, default `true`) — OwnTone copies `offset_ms`
  into an output's session when it builds it and declines to change a
  session that is already playing (`player.c:2937-2944`), so a new
  value only takes effect on the next enable. With `relatch` the
  sidecar cycles each currently-selected AirPlay output (disable, brief
  pause, enable) so the change lands immediately, at the cost of a
  short dropout on those receivers. An output already `latched` at the
  requested value is NOT cycled — the dropout is audible, and a retried
  or repeated call must not cost one.

Response: the same shape as `sync.airplay_offset`, plus
`"relatched": ["<output_id>", ...]` (cycled) and
`"unchanged": ["<output_id>", ...]` (already carrying this value, so
skipped).

Sign is verified against OwnTone's source, not assumed:
`docs/json-api.md` ("positive value means delay"),
`outputs/fifo.c:262-266` (`delay_ms += device->offset_ms`), and
`outputs/airplay.c:1598` + `:2180` (`cur_stamp.pos -=
session->offset_samples`, which maps every sample to a later instant on
the receiver).

The value is persisted by OwnTone in `speakers.offset_ms` and survives
a graceful restart, so the sidecar never trusts the stored value: it
rewrites the offset before every enable and writes `0` on every
disable, on leaving whole-home mode, and on shutdown.

### `sync.set_output_trims_ms`

Set the per-output USER delay trims — how much each individual speaker
is held back to compensate its distance from where the listener sits
(1 ms of air ≈ 34 cm).

Request:
```json
{"method":"sync.set_output_trims_ms",
 "params":{"trims_ms":{"<device_id>":12},"relatch":true}}
```

- `trims_ms` (optional, object, default `{}`) — SyncCast device id →
  milliseconds. The ids are the same ones `device.add` and
  `device.set_volume` use. **Full replacement, not a patch**: any id the
  caller omits is reset to `0`, so clearing every trim is
  `{"trims_ms":{}}` and no forgotten key can leave a stale trim behind.
  Each value is clamped to ±`OUTPUT_TRIM_LIMIT_MS` (400). That bound is
  on the NORMALISED value on the wire, not on the ±200 ms of signed
  intent the UI offers: the caller slides the whole set up so the earliest
  speaker sits at `0`, which can put the entire 400 ms span on one output.
- `relatch` (optional, default `true`) — same meaning and same cost as
  in `sync.set_airplay_offset_ms`. Only outputs whose COMPOSITE offset
  actually changed are cycled.

Response: the same shape as `sync.airplay_offset` (which now also
reports `output_trims_ms`, `effective_offset_by_output_ms` and
`max_output_trim_ms`), plus `relatched` / `unchanged`.

**Relationship to `sync.set_airplay_offset_ms` — they ADD, neither
overrides the other.** That call carries `L_local`, a SYSTEM correction
cancelling the local leg's pipeline latency, and it is global. This one
carries the human's per-speaker preference. An output ends up carrying
`clamp(airplay_offset_ms + trim_ms[device])`, and only the SUM is
clamped against OwnTone's ±2000 ms range, so a user trim can never push
the composite into an opaque REST 400. An output nobody has trimmed
carries exactly the system correction, unchanged from before this method
existed.

Values arrive non-negative in practice: the router normalises the
signed user intent (`DelayTrimNormalizer`) so the earliest speaker sits
at 0 and nothing is ever asked to play early — which is impossible on
both legs. Negative values are nonetheless accepted and clamped rather
than trusted.

Cleanliness is inherited from the offset machinery: the composite is
written before every enable, `0` is written on every disable, and
leaving whole-home mode or shutting down zeroes every row this process
touched.

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
  "device_id":"...","state":"<state>",
  "rtt_ms":3.2,"buffer_ms":1820,"last_error":null
}}
```

`state` is one of:

| state | Emitted when | UI sync-dot colour |
|---|---|---|
| `added` | Device first registered via `device.add` | – |
| `streaming` | `stream.start` accepted; PCM is flowing | – |
| `connecting` | Sidecar is calling OwnTone REST `set_output_enabled` (or waiting for OwnTone's mDNS scan to discover the receiver). Emitted at the start of every reconcile attempt for an enabled device. | yellow |
| `connected` | OwnTone REST confirmed `selected=True` for this device's output (verified via post-call `/api/outputs` poll). Audio is wired up. | green |
| `failed` | REST returned non-200, or post-call verification observed `selected=False`, or OwnTone never discovered the receiver within the 30 s deferred-reconcile budget. `last_error` carries a short reason string. | red |
| `disconnected` | User toggled the device off (sidecar issued `set_output_enabled false`). | grey |

Notes:

- `connecting`/`connected`/`failed`/`disconnected` describe the wiring
  state between sidecar and OwnTone REST. `added`/`streaming` describe
  the audio-data lifecycle. The two are independent (e.g. a device can
  be `streaming` but not `connected` for a brief window during the
  start-stream race that the sidecar's deferred reconcile resolves).
- The Swift router caches the most recent state per device and surfaces
  it to the UI via `Router.connectionState(deviceID:)` and
  `Router.connectionStatesSnapshot()`. The menubar polls the snapshot
  once per second.
- `last_error` is only populated for `failed`; it's a free-form short
  string suitable for inline display ("OwnTone never discovered
  receiver", "REST error: ...", etc.). The UI shows it under the
  device row when the dot is red.

Emitted at most once per second per device for the legacy informational
states; emitted ON EVERY transition for the wiring states (so the UI
sees timely yellow→green/red transitions).

### `pairing.status` / `pairing.begin` / `pairing.submit_pin` / `pairing.cancel`

Interactive AirPlay pairing. Every one of these returns in MILLISECONDS.

That is a hard contract, not a nicety. The sidecar's read loop awaits each
handler inline before reading the next request, so a handler that blocked for
the human-scale PIN window would freeze every other call — including
`stream.stop`, leaving the user unable to stop their own audio. The wait lives
in a background task inside the sidecar and progress arrives as
`event.pairing_state`.

`device_key` is the receiver's stable key: `ap:<AIRPLAY_DEVICE_ID>`, or
`name:<display name>` for an endpoint that published no `deviceid`.

```json
{"method":"pairing.status","params":{"device_key":"ap:0200CAFE0001"}}
→ {"device_key":"ap:0200CAFE0001","state":"required","required":true,
   "paired":false,"last_error":null}

{"method":"pairing.begin","params":{"device_key":"ap:0200CAFE0001"}}
→ {"state":"awaiting_pin"}

{"method":"pairing.submit_pin","params":{"device_key":"ap:0200CAFE0001","pin":"1234"}}
→ {"accepted":true,"state":"verifying"}

{"method":"pairing.cancel","params":{"device_key":"ap:0200CAFE0001"}}
→ {"cancelled":true}
```

The PIN travels in the request body only. It is never placed in a URL, never
logged, and never echoed back in a result or an error — errors from
`pairing.*` methods are replaced with fixed strings precisely because an
upstream exception can quote the request body.

### `event.pairing_state`

```json
{"method":"event.pairing_state","params":{
  "device_key":"ap:0200CAFE0001","state":"awaiting_pin","last_error":null
}}
```

`state` is one of:

| state | Meaning | UI |
|---|---|---|
| `not_required` | The receiver accepts audio without pairing. | no chrome |
| `required` | The receiver demands a credential we do not hold. | "Needs pairing" + Pair button |
| `awaiting_pin` | The REMOTE receiver is showing a four-digit code on its OWN screen (a Mac mini on its display); we are waiting for the user to read it there and type it back. This Mac is never a pairing target under direction B. | PIN entry sheet with countdown |
| `verifying` | The PIN was submitted and is being checked. | spinner |
| `paired` | A credential is stored and accepted. | no chrome |
| `failed` | The attempt failed. `last_error` is a fixed, secret-free string. | "Try again" |
| `cancelled` | The user cancelled. | "Try again" |
| `timed_out` | Nobody entered the PIN inside the 240 s window. | "Try again" |

Retrying is ALWAYS user-initiated. An automatic retry would throw another
full-screen code over whatever the user is doing.

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
| -32004 | Pairing required before this receiver can be used |
| -32005 | A pairing attempt is already in flight for this receiver |
| -32006 | Pairing failed |
| -32099 | Protocol version mismatch |

## Threading model

- Sidecar runs an asyncio event loop on the main thread.
- Audio socket is read on a dedicated thread that pushes frames into a per-device asyncio queue via `loop.call_soon_threadsafe`.
- Each AirPlay receiver gets its own pyatv stream coroutine.
- Backpressure: if any per-device queue exceeds 4×buffer_ms of frames, drop oldest and emit `event.error` with code `BACKPRESSURE_DROP`.

## Future extensions

- `transport: "snapcast"` — snapcast-server backend for non-AirPlay receivers
- `transport: "rtp"` — generic RTP for Linux receivers
