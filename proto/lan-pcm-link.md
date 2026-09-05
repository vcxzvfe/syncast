# SyncCast LAN PCM link — wire protocol v1

The protocol SyncCast (the **sender**) speaks to `synccast-receiver` (the
**receiver**), a small daemon on a second Mac that plays what it is sent on a
local output device.

It is not AirPlay. The point of having it at all is latency: AirPlay's buffer
is ~1.8 s, which is fine for whole-home listening and useless for a speaker
that has to play in time with the speakers next to the person listening. This
link targets **≤ 100 ms end to end** with one side on Wi-Fi, and ~60 ms wired,
so a receiver can be one leg of the local Stereo path alongside the sender's
own outputs.

Both repositories implement this document. If an implementation has to deviate,
the deviation belongs here first.

## Transport

| | |
|---|---|
| Discovery | Bonjour `_synccast-pcm._udp` |
| Control | TCP on the advertised port, newline-delimited JSON (UTF-8) |
| Audio | UDP to the port the receiver names in `hello_ack` |
| Format | 48 000 Hz, 2 channels interleaved, **Int16 little-endian** |
| Packet | 240 frames = exactly 5 ms = 960 bytes of PCM |
| Endianness | every multi-byte header field is little-endian |

Int16 rather than Float32: the wire is a LAN, the receiver converts to Float32
before its DAC anyway, and doubling the bandwidth buys nothing audible at these
levels.

### TXT record

| Key | Value |
|---|---|
| `v` | `1` — protocol version |
| `name` | friendly name to show in the sender's UI |
| `token` | first 8 hex characters of the pairing token — a HINT, never the secret |
| `rate` | `48000` |

The Bonjour **instance name** is the receiver's identity. The sender keys
everything it remembers about a receiver — the token, the playout target, the
equalizer, the stereo image, the channel matrix — on `lan:<instance name>`.
`name` is cosmetic and may change without losing any of that.

## Audio packet (UDP)

24-byte header, then `frames × 2 × 2` bytes of PCM.

```
offset size field
0      4    u32 magic      = 0x53435043  ("SCPC", so the wire bytes are 43 50 43 53)
4      4    u32 stream_id  identifies the sender's session
8      4    u32 seq        +1 per packet, wraps
12     8    u64 play_at_ns SENDER monotonic ns at which frame 0 of this packet
                           must leave the receiver's DAC
20     4    u32 frames     = 240
24     960  Int16 LE interleaved L,R,L,R,…
```

Receiver behaviour:

- Map `play_at_ns` into its own clock with the current offset estimate and
  schedule playout.
- A packet whose play time has already passed is dropped and counted `late`.
- A missing sequence number is zero-filled and counted `lost`.
- A packet with the wrong magic, the wrong `frames`, or the wrong total length
  is discarded without counting — it is not ours.

## Control messages (TCP, one JSON object per line)

### Sender → receiver

```json
{"type":"hello","v":1,"token":"<shared token>","name":"<sender name>",
 "rate":48000,"channels":2,"frames_per_packet":240,"stream_id":<u32>}
{"type":"gain","linear":<0..1>,"muted":<bool>}
{"type":"latency","target_ms":<int>}
{"type":"ping","t1":<sender monotonic ns>}
{"type":"bye"}
```

- `hello` opens the session. Exactly once per connection.
- `gain` carries the master level for this leg as **linear amplitude**, plus
  the mute flag. Sent on connect and whenever it changes — never on a timer.
- `latency` carries the playout target the receiver must honour. Sent on
  connect and on change. Range 30…300 ms, default 90.
- `ping` every 1000 ms, doubling as the keep-alive. **5 s without one and the
  receiver stops and mutes.**

### Receiver → sender

```json
{"type":"hello_ack","v":1,"udp_port":<int>,"device":"<output device name>",
 "device_uid":"<uid>","hw_volume":<bool>,"buffer_ms":<int>}
{"type":"pong","t1":<echo>,"t2":<recv monotonic ns>,"t3":<send monotonic ns>}
{"type":"stats","late":<n>,"lost":<n>,"underrun":<n>,
 "buffer_ms":<float>,"ratio":<float>,"clip":<n>}
{"type":"error","message":"..."}
```

- `hello_ack` is what starts the audio: the sender opens its UDP socket to
  `udp_port` on the address the control connection resolved to.
- `hw_volume` says whether the receiver can carry `gain` in its output device's
  own volume control, or has to apply it as software gain.
- `stats` every 1000 ms.
- `error` on a bad token, followed by a close. Send the error and give it time
  to leave before closing, or the sender sees an opaque disconnect instead of a
  reason it can show the user.

Both sides must ignore an unparseable line rather than dropping the session: a
peer from a future build may say things this one does not know.

## Clocks

`mach_absolute_time` converted to nanoseconds, on both sides. Monotonic, never
wall clock. The two machines' epochs are unrelated, and the offset between them
is expected to be large.

**Offset/RTT** from ping/pong, NTP style with the sender stamping `t4` on
receipt:

```
offset = ((t2 − t1) + (t3 − t4)) / 2      (receiver clock − sender clock)
rtt    = (t4 − t1) − (t3 − t2)
```

Keep a sliding window (~16 samples) and take the **minimum-RTT** sample as
truth — a long round trip means the packet queued somewhere, and a queued
packet's offset carries that queue as error. Smooth the chosen offset with an
EMA.

## Rate locking

The sender's `play_at_ns` is derived from the **ring frame number**, not from
its send timer: `play_at_ns = ringTime(frame) + target_ms`, where `ringTime`
maps capture-ring frames to sender nanoseconds through a slow, deadbanded loop
(`RingWriteClock`). Consecutive packets are therefore one packet apart at the
sender's *producer's* real rate, and the receiver that follows those timestamps
is locked to the audio source rather than to a timer on either machine.

The receiver's own DAC clock still differs. It closes that with a **water-level
PI loop driving a fractional resampler** — the ring fill level is the phase
detector, the ratio is nudged by at most ±200 ppm — and re-anchors (jumps) only
when the level error exceeds ±20 ms. `stats.ratio` reports where the loop has
settled.

The jitter-buffer target is `target_ms` from the sender. The receiver adds its
own device latency (`kAudioDevicePropertyLatency` + safety offset + buffer
frame size) on top, so `play_at_ns` is honoured **at the DAC**, not at the
render callback.

## Volume

The sender forwards its master as `gain.linear` (0…1 amplitude, already through
the dB law) plus `muted`. The receiver applies it as **hardware volume** when
its output device exposes `kAudioDevicePropertyVolumeScalar` — converting
amplitude → scalar with that device's own dB law — and as software gain
otherwise. `hello_ack.hw_volume` reports which.

Per-device balance, equalizer, stereo image and channel matrix are applied on
the **sender** before packetising. The receiver plays what it is given.

## Security

- **LAN only.** The sender refuses to send to anything outside RFC1918,
  link-local, loopback and their IPv6 equivalents. The link carries
  unencrypted PCM authenticated by a shared secret; that is a reasonable trade
  inside a home network and not one to make across the internet.
- **Shared token.** The receiver generates one on first run, prints it in its
  log, and advertises only the first 8 hex characters in TXT. The sender must
  send the full token in `hello`; a wrong one gets `error` and a close.
- The sender stores the token in the **keychain**, one item per receiver, not
  in `UserDefaults`.
- The token is never logged on either side, and never appears in the sender's
  diagnostics line.
