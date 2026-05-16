<div align="center">

# SyncCast

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
  - **AirPlay experimental mode** — local + AirPlay routing through the OwnTone-backed AirPlay pipeline. Multiple AirPlay receivers are generally handled by AirPlay's own timing domain, but Local + AirPlay delay still needs robust passive calibration and can drift after AirPlay interruptions, volume changes, or route changes.
  - **Stereo mode** — local CoreAudio outputs only, defaulting to Direct Stereo. This is the currently stable path and is suitable for video.
- Active acoustic calibration tones are disabled in normal builds. The current calibration R&D path is passive no-probe measurement from real program audio plus a microphone, with fail-closed confidence gates.
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
- **Microphone permission** — optional and only for explicit passive diagnostics. Normal playback and Stereo mode do not use the microphone or play calibration tones.
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
# 1) Clone and bootstrap (BlackHole + OwnTone + Python deps)
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

## Usage

1. **Launch SyncCast.** Look for the icon in the macOS menubar.
2. **Grant Screen Recording** only if you use an SCK capture path and macOS prompts for it, then quit and reopen once.
3. **Pick a mode** in the popover:
   - *AirPlay experimental* — AirPlay receivers plus selected local outputs. Expect latency and calibration limitations.
   - *Stereo* — local outputs only, low-latency aggregate device, suitable for video.
4. **Tick the devices you want.** Discovery runs continuously; new AirPlay receivers and audio devices appear within a few seconds.
5. **Play music from anything** — Music.app, Spotify, a browser tab, mpv. In Stereo, macOS routes audio through the Direct Stereo output; capture-dependent modes use the selected capture backend.

## Project status

> **Alpha. Experimental. Use at your own risk.**

What works:
- Local Stereo default path that bypasses ScreenCaptureKit
- System audio capture via ScreenCaptureKit for fallback/capture-dependent paths
- Local Stereo routing through an Aggregate Device
- AirPlay 2 multi-target streaming via the OwnTone-backed sidecar
- Mode switching, device discovery, per-device volume
- Local `.app` bundling with self-signed codesigning

What's still rough:
- Local + AirPlay automatic alignment is not production-reliable yet. Passive no-probe measurement and conservative correction gates are under active development.
- ScreenCaptureKit can trigger DRM playback blocks; Local Stereo now defaults to Direct Stereo, while Process Tap / AirPlay capture validation remains in progress.
- Active acoustic probe calibration is lab-only and disabled by default because high-band tones were audible on real hardware.
- Not notarized — Gatekeeper warnings are normal on first launch.
- No first-run wizard yet; `bootstrap.sh` is the on-ramp.
- AirPlay device pairing flow is minimal (relies on `pyatv`).
- Architecture is stable but tests against real receivers are still partly manual.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for what's next.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — full system design.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — phased plan and current status.
- [`docs/adr/`](docs/adr/) — Architecture Decision Records (one per cross-cutting choice).
- [`docs/round11_manual_first_design.md`](docs/round11_manual_first_design.md) — design notes for the current iteration.
- [`proto/`](proto/) — IPC schemas between the Swift router and the Python sidecar.
- [`sidecar/README.md`](sidecar/README.md) — sidecar internals and protocol.

## Contributing

Issues, ADRs, and PRs are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md). Code style is SwiftPM defaults for Swift and `ruff` + `mypy --strict` for Python; one ADR per cross-cutting design change.

## License

[MIT](LICENSE) © 2026 Zifan and SyncCast contributors.

## Acknowledgements

- **[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)** — Apple's modern system-wide audio capture API.
- **[OwnTone](https://owntone.github.io/owntone-server/)** (forked-daapd) — the only open-source AirPlay 2 sender today that can PTP-lock multiple receivers to a single master.
- **[pyatv](https://pyatv.dev)** — AirPlay 2 / HAP discovery and pairing.
- Built with the [Claude Code](https://claude.com/claude-code) multi-agent workflow — planning, implementation, review, and packaging coordinated across parallel worktrees.
