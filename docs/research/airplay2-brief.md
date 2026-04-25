# AirPlay 2 Sender Brief — SyncCast

_Last updated: 2026-04-25. Targets: Xiaomi Sound, Mac mini "AirPlay Receiver", HomePod / 3rd-party AirPlay 2 speakers._

## Executive summary

The honest state of the open-source AirPlay 2 **sender** ecosystem in 2026 is that there is exactly **one** mature, actively maintained project that can drive multiple AirPlay 2 speakers in sync: **OwnTone** (formerly forked-daapd). **pyatv** can stream audio, but only via the legacy RAOP / AirPlay 1 path; AirPlay 2 HAP-encrypted RAOP is still unimplemented (`v0.17.0` "Velma", Jan 2026, added per-device *volume* but not encrypted streaming). pyatv's `set_output_devices` API is a *remote-control* command sent to an Apple-made leader (Apple TV / HomePod) — it does **not** make pyatv itself the multi-target source, so it cannot drive a Xiaomi Sound + Mac mini + HomePod group from the Python sidecar.

**Recommendation: do NOT depend on pyatv as the multi-target sender.** Use it only for discovery, pairing, and AirPlay-1-class single-target test paths. Adopt OwnTone's `outputs/airplay.c` + `raop.c` (GPL-2.0, ~256 KB of C, with working PTP and group SETPEERS) as the production AirPlay 2 sender, embedded as a sidecar process and controlled over its JSON API or a thin C-ABI shim. Plan B if GPL is unacceptable: port the same logic to Rust on top of `openssl`/`ring` + `libplist`, using OwnTone as the reference.

---

## 1. pyatv (postlund/pyatv) — feature audit

**Version:** `v0.17.0 "Velma"` released 2026-01-21. Active (last push 2026-04-09, 1.1 k stars). ([Releases](https://github.com/postlund/pyatv/releases))

### What works

- **Streaming API:** `atv.stream.stream_file(source)` and `atv.stream.play_url(url)`. `stream_file` accepts a path, `io.open(...)`-style binary file object, `sys.stdin.buffer`, or an `asyncio.StreamReader` (so an `ffmpeg` subprocess pipe is fine). Internally it transcodes to L16 PCM wrapped in ALAC frames. ([Stream docs](https://pyatv.dev/development/stream/))
- **Source formats:** MP3, WAV, FLAC, OGG. Raw PCM is *not* a documented input format, but you can feed PCM via WAV-headered bytes or by piping through `ffmpeg -f s16le ... -f wav -`.
- **Per-device volume:** `v0.17.0` added `set_volume` per connected device (PR #2673). ([CHANGES.md](https://github.com/postlund/pyatv/blob/master/CHANGES.md))
- **Multi-room *control*:** `output_devices`, `add_output_devices`, `remove_output_devices`, `set_output_devices`. Critical caveat — the docs explicitly state "the AirPlay leader device returns a list of output devices, other connected AirPlay devices return an empty list." This API is for telling an *existing* Apple-made leader (Apple TV / HomePod) to extend its group. pyatv is **not** the leader and cannot fan out from a Mac sidecar to N speakers itself. ([Supported features](https://pyatv.dev/documentation/supported_features/))
- **Discovery & pairing:** Robust. HAP transient pairing for control channels works.

### What does NOT work for SyncCast

- **AirPlay 2 encrypted RAOP audio.** From the protocol docs: "Only legacy pairing is supported for RAOP… encryption has not been implemented for HAP-based authentication." Streaming therefore falls back to AirPlay 1 RAOP, which post-iOS 14 HomePods and current Xiaomi Sound firmware accept only in transient mode if at all. ([Protocols](https://pyatv.dev/documentation/protocols/), [Issue #1255](https://github.com/postlund/pyatv/issues/1255))
- **Multi-target synchronized streaming from pyatv.** No `SETPEERS` / PTP sender code exists. Only one stream at a time — `stream_file` raises `InvalidStateError` on a second concurrent call.
- **PTP timing primitives are not exposed** — pyatv hides clock setup entirely, you cannot adjust `latencyMin`/`latencyMax` or read PTP offset.
- **End-to-end latency:** documented as "roughly a two second delay until audio starts to play" — fixed buffer, no API to shrink it.

### Minimal single-receiver example

```python
import asyncio, pyatv
from pyatv.const import Protocol

async def main():
    loop = asyncio.get_event_loop()
    confs = await pyatv.scan(loop, identifier="HomePod-Living")
    atv = await pyatv.connect(confs[0], loop, protocol=Protocol.RAOP)
    try:
        # File, fileobj, sys.stdin.buffer, or an asyncio StreamReader all work.
        await atv.stream.stream_file("/tmp/sample.wav")
    finally:
        atv.close()

asyncio.run(main())
```

### Minimal "multi-target" via the existing-leader trick

This only works if one of the targets is an Apple TV or HomePod *already configured as a leader*; it sends a remote-control command, not audio:

```python
# Connect to the leader (must be Apple-made), then have IT pull peers in.
leader = await pyatv.connect(leader_conf, loop, protocol=Protocol.AirPlay)
await leader.audio.set_output_devices(
    "FFFFFFFF-AAAA-BBBB-CCCC-XIAOMISOUND01",
    "FFFFFFFF-AAAA-BBBB-CCCC-MACMINIRECV01",
)
# Now stream to the leader; the leader fans out via its own AirPlay 2 stack.
await leader.stream.stream_file(pcm_pipe)
```

For a sidecar that has no Apple TV in the room, this path is unusable.

---

## 2. Alternative open-source senders

| Project | License | Sender? | AirPlay 2 multi-sync | Maintenance | Notes |
|---|---|---|---|---|---|
| **OwnTone** (`owntone/owntone-server`) | GPL-2.0 | **Yes** | **Yes**, with PTP | Active (push 2026-04-22, 2.5 k stars) | Production-grade. `src/outputs/airplay.c` (132 KB) + `raop.c` (124 KB). Has a JSON API and a pipe input. ([repo](https://github.com/owntone/owntone-server)) |
| **shairport-sync** (`mikebrady/shairport-sync`) | MIT | **Receiver only** (confirmed) | n/a | Active | Useful if Mac mini path needs a non-Apple receiver fallback. ([Issue #535](https://github.com/mikebrady/shairport-sync/issues/535)) |
| **AirConnect** | MIT | Sender (UPnP→AirPlay bridge) | Single-target only | Slow | AirPlay 1 only in practice. |
| **goplay2**, **airguitar**, **rareport**, **airplay-rs**, **SteeBono/airplayreceiver** | mixed | **Receivers** | n/a | mixed | All RX-side. None are senders. |
| **rust-raop-player** (`LinusU/rust-raop-player`) | MIT | Sender | RAOPv2 only, no AirPlay 2 PTP | Stale | AirPlay 1 sync only — same class as pyatv's path. |

**Verdict:** OwnTone is the only credible open-source AirPlay 2 sender. Everything else is either receiver-side, AirPlay-1-only, or stale.

### Embedding OwnTone

OwnTone is monolithic (~250 source files, libevent-based event loop) but the AirPlay code is well-isolated under `src/outputs/`. Two viable embed strategies:

1. **Sidecar process + JSON API.** Run owntoned as a subprocess, feed PCM via its pipe input (`src/inputs/pipe.c`), control via its REST API (`/api/outputs`, `/api/player/play`). Minimum invasive; GPL boundary stays at process boundary. This is what we recommend.
2. **Hard fork the AirPlay output.** Lift `airplay.c`, `airplay_events.c`, `raop.c`, `rtp_common.c`, plus crypto (`evrtsp/`, libplist, libsodium) into a standalone library. ~5–8 KLOC; significant work but yields a thin static lib. Watch the GPL — your binary becomes GPL-2.0.

---

## 3. Protocol facts (what the architecture must respect)

- **End-to-end latency:** AirPlay 2 default is a **~2 s buffer** before playback starts. SETUP can declare `latencyMin`/`latencyMax` (samples) — example values from the reverse-engineered RTSP doc are 11 025 / 88 200 samples (≈ 250 ms / 2 s @ 44.1 kHz). HomePods report `outputLatencyMicros ≈ 400 000` (400 ms). For SyncCast, **delay-pad local outputs by ~2 s** to align with the AirPlay floor; you can attempt to negotiate `latencyMin = 11025` for lower delay but support varies per device. ([RTSP](https://emanuelecozzi.net/docs/airplay2/rtsp/))
- **PTP & multi-target sync:** The sender provisions a PTP master (or itself acts as one) and SENDS `timingPeerInfo` + `timingPeerList` to each receiver via SETUP, then ties them together with the binary-plist `SETPEERS` command containing the IPv4/IPv6 list of all members. **Sync is *not* free** — the sender must (a) run/select a PTP master on the LAN, (b) issue SETPEERS to every receiver, (c) feed the same RTP timestamp stream to all. Multi-target sync is a *first-class feature of the protocol* but a *non-trivial implementation effort* in the sender. NTP-only mode exists for AirPlay-1 fallback and locks the sync floor at ~40–80 ms jitter; PTP brings it to single-digit ms.
- **Codecs:** `LPCM` (16-bit, typ. 44.1 kHz stereo), `ALAC`, `AAC-LC`, `AAC-ELD`, `OPUS`. HomePod speakers prefer ALAC at 44.1 k/16-bit; Xiaomi Sound and most third-party advertise ALAC + AAC-LC. **Plan to encode ALAC 44.1/16 stereo as the lowest-common-denominator.** Higher rates (48/96 k) negotiate but break sync on mixed groups.
- **Discovery in 2026:** Advertise **`_airplay._tcp` on port 7000** and **`_raop._tcp` on port 49152** (some devices declare an alternate port in TXT). On the *sender* side, look for `_airplay._tcp` first — its `features` 64-bit bitfield tells you AirPlay 2 capability. `_raop._tcp` is still emitted by every device for backward compatibility but is the AirPlay 1 path; ignore receivers that *only* advertise `_raop._tcp` if you want AirPlay 2 features. Key TXT fields: `features`, `flags`, `pi` (UUID), `gid` (group UUID), `pk` (public key), `model` (`AudioAccessory*` = HomePod, `AppleTV*` = Apple TV). ([Service discovery](https://openairplay.github.io/airplay-spec/service_discovery.html))

---

## 4. macOS "AirPlay Receiver" specifics

A Mac mini with **System Settings → General → AirDrop & Handoff → AirPlay Receiver = On** advertises `_airplay._tcp` with `model=Mac*` (e.g. `Macmini9,1`) and a `features` bitfield that typically includes `SupportsAirPlayAudio`, `SupportsAirPlayVideo`, `SupportsAirPlayScreen`, `SupportsBufferedAudio`, `SupportsHKPairingAndAccessControl`, and `MetadataFeatures` for artwork/title. Known quirks vs HomePod:

- **Cross–Apple-ID restriction.** Default policy is "Current User"; for a Mac on a different Apple ID than the sender, set **Allow AirPlay for: Everyone on the same network** (or "Anyone") and set a PIN to `Never` if the sidecar can't prompt for one. Without this, mDNS shows the device but RTSP returns `403`.
- **Sleep/Power Nap.** macOS un-publishes `_airplay._tcp` when the Mac sleeps. We must (a) detect republish via mDNS goodbye/hello, (b) optionally send a wake-on-LAN before dispatching audio.
- **Latency profile.** Mac receiver reports a *higher* `outputLatencyMicros` (~600–800 ms) than HomePod (~400 ms). This pulls the group floor up — budget 2.5 s rather than 2 s in mixed groups including a Mac.
- **No PTP-Boundary-Clock role.** Unlike HomePod (which can serve as PTP grandmaster for its group), the Mac AirPlay Receiver acts only as a follower. So **the SyncCast sender must always provision the PTP master itself** when a Mac is in the group.
- **Codec quirk.** macOS receiver accepts ALAC and AAC-LC but **rejects OPUS** in our local testing notes from `sync-brief.md`. Stick to ALAC.

---

## 5. Plan B — if/when pyatv proves insufficient

In order of preference:

1. **OwnTone as a sidecar (recommended).** Spawn `owntoned` from SyncCast, point its `pipe` input at our Python audio source, drive its REST API for output enable/disable + per-device volume. Pros: works today, GPL boundary stays clean (separate process), maintained. Cons: heavyweight (~30 MB binary, sqlite cache), GPL forces us to either keep it as a separately distributed sidecar or relicense the whole app.
2. **Fork OwnTone's `outputs/airplay.c` into a thin C library + Python `cffi` bindings.** Roughly 2–3 weeks of work to extract `airplay.c`, `raop.c`, `rtp_common.c`, replace the libevent dispatch with libuv or asyncio bridge, and stub out the database/Spotify hooks. Result is GPL-2.0 still (license inherits) but binary footprint ≪ 1 MB.
3. **Rust port using OwnTone as the spec.** New crate; reuse `libplist` bindings, `ring` for ChaCha20-Poly1305, write the RTSP state machine fresh. ~6–10 weeks. License-clean (we choose). Highest engineering cost, best long-term.
4. **Apple's `AVAudioEngine` + `MPRemoteCommandCenter` via PyObjC on the Mac.** Public AVFAudio APIs route audio to system AirPlay outputs that the user has selected in *Sound prefs*; this is allowed in App Store builds. **It does not let us programmatically pick or group AirPlay 2 receivers** — that requires `MPVolumeView`/`AVRoutePickerView` in a UI, or private API. Acceptable as a *single-target* fallback driven by a SwiftUI route picker the user clicks; not acceptable as a programmatic multi-target solution.
5. **Last resort: private framework `AirPlayReceiver`/`AirPlaySupport` on macOS.** Functions like `APSCopyServerVersion`, `APSStartGroupSession`. Works, but Apple changes signatures every major release; we'd need a per-macOS quirk table. Distributing outside the App Store makes this *legal*, but a maintenance liability. Only consider if (1)–(3) are blocked.

### Decision matrix

| Path | Multi-target sync | Effort | License | Risk |
|---|---|---|---|---|
| pyatv only | **No** | Low | MIT | n/a — won't meet requirement |
| OwnTone sidecar | **Yes** | Low–Med | GPL-2.0 (sidecar) | Low |
| OwnTone fork to lib | Yes | Med–High | GPL-2.0 | Med |
| Rust port | Yes | High | We choose | Med–High |
| AVAudioEngine + UI route picker | Single only | Low | Apple public | n/a — won't meet requirement |
| Private frameworks | Yes | Med | Apple private | High (each macOS rev) |

---

## Sources

- pyatv documentation: <https://pyatv.dev/>, [Stream](https://pyatv.dev/development/stream/), [Supported features](https://pyatv.dev/documentation/supported_features/), [Protocols](https://pyatv.dev/documentation/protocols/)
- pyatv repo & changelog: <https://github.com/postlund/pyatv>, [CHANGES.md](https://github.com/postlund/pyatv/blob/master/CHANGES.md), [Issue #1255 (AirPlay 2 metadata / RAOP encryption status)](https://github.com/postlund/pyatv/issues/1255), [Issue #1059 (RAOP origin)](https://github.com/postlund/pyatv/issues/1059), [Issue #2204 (force AirPlay version)](https://github.com/postlund/pyatv/issues/2204)
- OwnTone: <https://github.com/owntone/owntone-server>, [`src/outputs/airplay.c`](https://github.com/owntone/owntone-server/blob/master/src/outputs/airplay.c), [docs](https://owntone.github.io/owntone-server/)
- AirPlay 2 reverse-engineering: [Cozzi internals](https://emanuelecozzi.net/docs/airplay2), [Cozzi RTSP](https://emanuelecozzi.net/docs/airplay2/rtsp/), [Cozzi service discovery](https://emanuelecozzi.net/docs/airplay2/discovery/), [openairplay spec](https://openairplay.github.io/airplay-spec/), [openairplay service discovery](https://openairplay.github.io/airplay-spec/service_discovery.html)
- Receivers (for context): [shairport-sync #535](https://github.com/mikebrady/shairport-sync/issues/535), [goplay2](https://github.com/openairplay/goplay2)
