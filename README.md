<div align="center">

# SyncCast

**Open-source macOS menubar app for synchronized multi-device audio routing.**

One song. Every speaker in the house. In sync.

[English](README.md) · [中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Status: Alpha](https://img.shields.io/badge/status-alpha-yellow)](#project-status)

</div>

---

## The problem

You have a HomePod in the living room, an AirPlay speaker in the kitchen, and a USB DAC in the bedroom. You want to play **one song everywhere, in sync**, from your Mac.

macOS gives you two half-solutions:

1. **Audio MIDI Setup → Multi-Output Device** — works for local outputs, but AirPlay 2 receivers drift and there's no per-device volume.
2. **Control Center AirPlay multi-room** — works for AirPlay 2 receivers only. The moment you AirPlay anywhere, you lose your local speakers.

Neither lets you fan one stream out to **local CoreAudio devices and AirPlay 2 receivers at the same time**. SyncCast does.

## What it does

- Captures the **system audio stream** on macOS using Apple's [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) — no virtual audio driver, no kernel extension, no root.
- Routes the captured stream to **multiple destinations simultaneously**:
  - Local CoreAudio outputs (built-in speakers, USB / HDMI / Thunderbolt DACs)
  - AirPlay 2 receivers (HomePod, Apple TV, Xiaomi Sound, third-party speakers, other Macs running AirPlay Receiver)
- Two mutually-exclusive modes, swapped in one click:
  - **Whole-home mode** — all selected outputs go through the AirPlay 2 pipeline, locked to a single PTP master for tight multi-room sync (~1.8 s latency, no video sync).
  - **Stereo mode** — local CoreAudio outputs only, via an Aggregate Device (~50 ms latency, video sync OK, no AirPlay).
- Lives quietly in the menubar. Pure user-space Swift + a small Python sidecar.

## Architecture

```
        ┌─────────────────────────────────────────────────────────────┐
        │  Any macOS app (Music, Spotify, Safari, Mpv, …)             │
        └────────────────────────────┬────────────────────────────────┘
                                     │   System audio
                                     ▼
        ┌─────────────────────────────────────────────────────────────┐
        │  ScreenCaptureKit  ── system-wide audio tap (no driver)     │
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

- **macOS 14 (Sonoma) or later** — ScreenCaptureKit audio capture is required.
- **Screen Recording permission** — you'll be prompted on first launch. (Despite the name, this permission gates audio capture too — there's no microphone or virtual driver involved.)
- **Xcode 15+** and **Python 3.11+** — only if you're building from source.
- An AirPlay 2 receiver and/or a CoreAudio output device — preferably both, that's the point.

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

> **Why install to `/Applications`?** macOS Tahoe's TCC silently denies Screen Recording for apps running from arbitrary paths. `install-app.sh` also re-signs in place so the signature matches the final bundle path.

A self-signed identity named `SyncCast Dev` (created via Keychain Access → Certificate Assistant) is detected automatically and gives you stable Screen Recording grants across rebuilds. Without it, you fall back to ad-hoc signing — works, but TCC will re-prompt every time.

## Usage

1. **Launch SyncCast.** Look for the icon in the macOS menubar.
2. **Grant Screen Recording** when prompted, then quit and reopen once.
3. **Pick a mode** in the popover:
   - *Whole-home* — all your AirPlay receivers and local outputs are streamed via AirPlay 2 (PTP-synced).
   - *Stereo* — local outputs only, low-latency aggregate device, suitable for video.
4. **Tick the devices you want.** Discovery runs continuously; new AirPlay receivers and audio devices appear within a few seconds.
5. **Play music from anything** — Music.app, Spotify, a browser tab, mpv. SyncCast captures it system-wide.

## Project status

> **Alpha. Experimental. Use at your own risk.**

What works:
- System audio capture via ScreenCaptureKit
- Local multi-output routing through an Aggregate Device
- AirPlay 2 multi-target streaming via the OwnTone-backed sidecar
- Mode switching, device discovery, per-device volume
- Local `.app` bundling with self-signed codesigning

What's still rough:
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
