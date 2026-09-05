<div align="center">

# SyncCast

> The virtual output device lives in its own repository, [SyncCastAudio](https://github.com/vcxzvfe/SyncCastAudio), included here as the git submodule `drivers/SyncCastAudio` — clone with `--recurse-submodules` or run `git submodule update --init`.

**Open-source macOS menubar app for experimental multi-device audio routing.**

Local Stereo is the stable path today. Local + AirPlay sync is active R&D.

[English](README.md) · [中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Status: Alpha](https://img.shields.io/badge/status-alpha-yellow)](#project-status)

</div>

---

## The problem

You have a HomePod in the living room, an AirPlay speaker in the kitchen, and a USB DAC in the bedroom. You want to play **one song everywhere** from your Mac, without giving up local speakers.

macOS gives you two half-solutions:

1. **Audio MIDI Setup → Multi-Output Device** — works for local outputs, but AirPlay 2 receivers drift and there's no per-device volume.
2. **Control Center AirPlay multi-room** — works for AirPlay 2 receivers only. The moment you AirPlay anywhere, you lose your local speakers.

Neither gives you a dependable Local + AirPlay mix with per-device control. SyncCast is an alpha attempt at that, with a stable local Stereo mode and an experimental AirPlay mode.

## What it does

- Captures the **system audio stream** on macOS for AirPlay/capture-dependent paths. Local Stereo now defaults to a Direct Stereo CoreAudio output path so local video playback does not need ScreenCaptureKit or Screen Recording.
- Routes the captured stream to **multiple destinations simultaneously**:
  - Local CoreAudio outputs (built-in speakers, USB / HDMI / Thunderbolt DACs)
  - AirPlay 2 receivers (HomePod, Apple TV, Xiaomi Sound, third-party speakers, other Macs running AirPlay Receiver)
- Two mutually-exclusive modes, swapped in one click:
  - **AirPlay experimental mode** — local + AirPlay routing through the OwnTone-backed AirPlay pipeline. Multiple AirPlay receivers are handled by AirPlay's own timing domain; the local leg is slaved to that same clock domain by a ring-level control loop, with a per-output millisecond trim for listening-position differences.
  - **Stereo mode** — local CoreAudio outputs only, defaulting to Direct Stereo. This is the currently stable path and is suitable for video.
- Acoustic (microphone) measurement was retired on 2026-08-09. SyncCast never opens the microphone and never plays calibration tones; alignment comes from the OwnTone clock domain instead.
- **Auto-connect profiles** — pick one output as a trigger (a specific monitor, dock or DAC, matched on its CoreAudio UID so a different display at a different desk changes nothing) and SyncCast switches to local Stereo with your chosen outputs the moment it appears. Optionally, when it goes away: stop, fall back to the built-in speakers, and force their level — 0 % is genuinely silent, so unplugging in public does not turn the laptop into a speaker.
- Lives quietly in the menubar. Pure user-space Swift + a small Python sidecar.

## Architecture

```
        ┌─────────────────────────────────────────────────────────────┐
        │  Any macOS app (Music, Spotify, Safari, Mpv, …)             │
        └────────────────────────────┬────────────────────────────────┘
                                     │   System audio
                                     ▼
        ┌─────────────────────────────────────────────────────────────┐
        │  Capture backend  ── SCK today, Process Tap in progress     │
        └────────────────────────────┬────────────────────────────────┘
                                     ▼
        ┌─────────────────────────────────────────────────────────────┐
        │            SyncCast Router (Swift, user-space actor)        │
        │  • Ring buffer + per-mode reconciliation                    │
        │  • Mode toggle: whole-home (AirPlay) vs stereo (local)      │
        │  • IPC bridge to Python sidecar over Unix socket            │
        └──────┬─────────────────────────────────┬────────────────────┘
               │ CoreAudio                       │ Unix socket  + PCM FIFO
               ▼                                 ▼
   ┌──────────────────────┐         ┌──────────────────────────────────┐
   │ Aggregate Device     │         │ Python sidecar (pyatv + OwnTone) │
   │  → built-in speakers │         │   AirPlay 2 RTSP / PTP sender    │
   │  → USB / HDMI DACs   │         └────────────┬─────────────────────┘
   └──────────────────────┘                      │ AirPlay 2
                                                 ▼
                              HomePod  ·  Apple TV  ·  3rd-party AirPlay  ·  other Macs
```

Sub-components:

| Component                          | What it does                                                      |
| ---------------------------------- | ----------------------------------------------------------------- |
| `apps/menubar/`                    | SwiftUI menubar app: device picker, mode toggle, volume controls. |
| `core/router/`                     | Audio capture, ring buffer, routing actor.                        |
| `core/discovery/`                  | CoreAudio + Bonjour device enumeration.                           |
| `sidecar/` (Python)                | Wraps `pyatv` (discovery / pairing) and `OwnTone` (PTP-locked multi-target AirPlay 2 sender). |
| `proto/`                           | JSON-RPC schemas exchanged over the Unix socket.                  |

## Requirements

- **macOS 14 (Sonoma) or later** — required for the current alpha.
- **Screen Recording permission** — not required for the default local Stereo path. It is still required for ScreenCaptureKit fallback/capture-dependent paths such as AirPlay unless Process Tap is selected.
- **Microphone permission** — never requested. No code path opens the microphone, and the app bundle carries no `NSMicrophoneUsageDescription`.
- **Xcode 15+** and **Python 3.11+** — only if you're building from source.
- An AirPlay 2 receiver and/or a CoreAudio output device — preferably both, that's the point.

## Download

Pre-built `.app` bundles are published as GitHub Releases:
[github.com/vcxzvfe/syncast/releases](https://github.com/vcxzvfe/syncast/releases)

The latest alpha is signed with a self-signed certificate. To run it:

```bash
unzip SyncCast.app.zip
mv SyncCast.app /Applications/
xattr -dr com.apple.quarantine /Applications/SyncCast.app
open /Applications/SyncCast.app
```

Or build from source — see below.

## Build and install (from source)

SyncCast isn't notarized yet, so you build it locally. Three steps:

```bash
# 1) Clone and bootstrap (silent sink + OwnTone + Python deps)
git clone https://github.com/<your-user>/syncast.git
cd syncast
./scripts/bootstrap.sh

# 2) Build the Swift menubar binary
( cd apps/menubar && swift build -c release )

# 3) Package as a .app bundle and install to /Applications
bash scripts/package-app.sh   # produces dist/SyncCast.app
bash scripts/install-app.sh   # copies to /Applications/SyncCast.app and re-signs
```

Then launch:

```bash
open /Applications/SyncCast.app
```

> **Why install to `/Applications`?** macOS Tahoe's TCC silently denies capture permissions for apps running from arbitrary paths. `install-app.sh` also re-signs in place so the signature matches the final bundle path.

Development installs use ad-hoc signing by default. That is fine for the default local Stereo / Direct Stereo path, which does not need Screen Recording. If you need stable TCC grants while testing SCK fallback or other capture-dependent paths, create a self-signed code-signing identity named `SyncCast Dev` and run package/install with `SYNCAST_USE_SYNCCAST_DEV=1`.

## System volume

In local **Stereo** mode SyncCast can put itself under the macOS volume UI: the
menu-bar slider, F11/F12, the volume HUD and third-party helpers (LinearMouse)
all control your speakers together, with no Accessibility permission and no
media-key interception.

It works by making a *virtual sink device* the default output — macOS gives any
such device a real volume control, unlike an aggregate — capturing it with a
Core Audio Process Tap, and re-applying the level on your real outputs
(hardware volume where the device has one, DDC/CI on displays that answer it,
software gain otherwise). While it runs, the Sound menu shows **SyncCast** (or
**BlackHole 2ch**) as the output; that is the sink, not a mistake.

```bash
# Which path will run, and which sink is installed:
( cd core/router && swift run SyncCastSystemSinkProbe )

# Added-latency budget (read-only, computed from device properties):
( cd core/router && swift run SyncCastSystemSinkProbe --latency )

# End-to-end check (takes the default output for a few seconds, restores it):
( cd core/router && swift run SyncCastSystemSinkProbe --smoke )
```

### Latency on the sink path

The sink path adds **~51 ms** on this hardware: 10.7 ms sink IO buffer +
30 ms ring floor + 10.7 ms output IO buffer. Device hardware latency is not
counted — every path pays it. Direct Stereo adds ~0, because apps render
straight into the aggregate with no capture and no ring.

Earlier notes in this repo claimed 71 ms and blamed 50 ms of it on the
Scheduler's safety margin. That was wrong: the Scheduler's backoff never
reaches `LocalOutput`'s read target, and the ring term was a hardcoded 100 ms
floor, so the real figure was ~121 ms. The floor is now sized per producer —
100 ms for the ScreenCaptureKit paths, 30 ms for the sink path's Process Tap,
which delivers regular 512-frame blocks and does not need the slack.

Tune it with `SYNCAST_SINK_RING_FLOOR_MS` (10…500; anything else logs a
warning and uses 30). Lower trades dropout headroom for latency — check the
`resync` / `underrun` / `minWater` counters in the health lines of
`~/Library/Logs/SyncCast/launch.log` before keeping a lower value.
**The 30 ms default has not been verified by listening yet.**

### Installing the SyncCast audio driver

SyncCast ships its own output-only virtual device (`SyncCastAudio.driver`,
2 ch / 48 kHz, no input stream, so no microphone-shaped permission anywhere).
Installing it needs an admin password because HAL plug-ins live in
`/Library/Audio/Plug-Ins/HAL`, and installing restarts coreaudiod — all audio
stops for a second or two.

```bash
bash drivers/SyncCastAudio/build.sh          # -> build/SyncCastAudio.driver
sudo bash scripts/install-driver.sh          # install + restart coreaudiod
sudo bash scripts/install-driver.sh --uninstall
```

The popover's **安装 SyncCast 音频驱动 / Install SyncCast audio driver** button
runs the same script through macOS's own authorization dialog. Restart SyncCast
afterwards — the path is resolved once per launch.

If the driver is not installed, SyncCast falls back to **BlackHole 2ch** when
that is present, and to the legacy Direct Stereo path (which still uses the
media-key event tap) when neither is. Force a path with
`SYNCAST_STEREO_PATH=sink|direct|capture`.

Whole-home mode uses the same preference order for the silent device it hides
behind 「AirPlay 全屋」, so **BlackHole is optional in every mode**. Once
`SyncCastAudio.driver` is installed you can remove it:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver
sudo killall coreaudiod
```

## Usage

1. **Launch SyncCast.** Look for the icon in the macOS menubar.
2. **Grant Screen Recording** only if you use an SCK capture path and macOS prompts for it, then quit and reopen once.
3. **Pick a mode** in the popover:
   - *AirPlay experimental* — AirPlay receivers plus selected local outputs. Expect added latency; per-output delay trims are available for fine alignment.
   - *Stereo* — local outputs only, low-latency aggregate device, suitable for video.
4. **Tick the devices you want.** Discovery runs continuously; new AirPlay receivers and audio devices appear within a few seconds.
5. **Play music from anything** — Music.app, Spotify, a browser tab, mpv. In Stereo, macOS routes audio through the system sink (or the Direct Stereo output when no sink is installed); capture-dependent modes use the selected capture backend.
6. **Use the normal volume controls.** On the sink path the system slider is the master and each device row is a balance on top of it. See [System volume](#system-volume).
7. **Tune a speaker (optional).** On a Local Stereo path that renders the audio itself (the system sink or a capture backend), each enabled output row gets a slider-icon button that opens a ten-band graphic equalizer for that speaker alone: 31.5 Hz … 16 kHz, ±12 dB in 0.5 dB steps, plus an overall trim and a bypass switch. Handy when one speaker's bass is overpowering. The curve is stored against that device's CoreAudio UID, so it is re-applied every time the device connects, and it never leaks onto a different display. Not available on the Direct Stereo path or in AirPlay experimental mode — SyncCast does not render those samples, and the row says so if you have a curve saved.
8. **Line up two speakers that are out of step (optional).** Some outputs — display panels in particular — add tens of milliseconds of their own audio processing and never report it, so they play noticeably behind the built-in speakers. On the same Local Stereo paths as the equalizer, each enabled output row carries a delay slider (−100…+100 ms, 1 ms ≈ 34 cm of extra distance): positive holds that output back, and only the difference between outputs matters, so the earliest one is always the reference. Devices that *do* report their latency honestly are lined up automatically before you touch anything; the slider covers the rest. Stored against the CoreAudio UID and re-applied on every connect, like the equalizer. No microphone is involved — you dial it in by ear.
9. **Set up auto-connect (optional).** With the devices you want ticked, open 自动连接 under the device list, pick the trigger device and press 「用当前选择创建规则」. From then on that selection is restored whenever the trigger appears — unless you have changed the selection yourself, in which case the rule stands down until the trigger is unplugged and reconnected, or you press 「重新应用规则」.

## Project status

> **Alpha. Experimental. Use at your own risk.**

What works:
- Local Stereo default path that bypasses ScreenCaptureKit
- System audio capture via ScreenCaptureKit for fallback/capture-dependent paths
- Local Stereo routing through an Aggregate Device
- AirPlay 2 multi-target streaming via the OwnTone-backed sidecar
- Mode switching, device discovery, per-device volume
- Per-device ten-band equalizer on the Local Stereo render paths, remembered by CoreAudio UID
- Per-device delay compensation on the same paths, seeded from reported hardware latency and remembered by CoreAudio UID
- Local `.app` bundling with self-signed codesigning

What's still rough:
- Local + AirPlay alignment now rides the OwnTone clock domain and has been verified by ear on one setup only; it has not been validated across a range of receivers or long sessions.
- ScreenCaptureKit can trigger DRM playback blocks; Local Stereo now defaults to Direct Stereo, while Process Tap / AirPlay capture validation remains in progress.
- Not notarized — Gatekeeper warnings are normal on first launch.
- No first-run wizard yet; `bootstrap.sh` is the on-ramp.
- AirPlay device pairing flow is minimal (relies on `pyatv`).
- Architecture is stable but tests against real receivers are still partly manual.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for what's next.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — full system design.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — phased plan and current status.
- [`docs/adr/`](docs/adr/) — Architecture Decision Records (one per cross-cutting choice).
- [`docs/HANDOFF.md`](docs/HANDOFF.md) — current state and open threads.
- [`proto/`](proto/) — IPC schemas between the Swift router and the Python sidecar.
- [`sidecar/README.md`](sidecar/README.md) — sidecar internals and protocol.

## Contributing

Issues, ADRs, and PRs are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md). Code style is SwiftPM defaults for Swift and `ruff` + `mypy --strict` for Python; one ADR per cross-cutting design change.

## License

[MIT](LICENSE) © 2026 SyncCast contributors.

## Acknowledgements

- **[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)** — Apple's modern system-wide audio capture API.
- **[OwnTone](https://owntone.github.io/owntone-server/)** (forked-daapd) — the only open-source AirPlay 2 sender today that can PTP-lock multiple receivers to a single master.
- **[pyatv](https://pyatv.dev)** — AirPlay 2 / HAP discovery and pairing.
- Built with the [Claude Code](https://claude.com/claude-code) multi-agent workflow — planning, implementation, review, and packaging coordinated across parallel worktrees.
