# SyncCast

> One audio source. Every speaker in the house. Built for macOS.

SyncCast is an open-source macOS menubar app that plays the same audio simultaneously across heterogeneous output devices — built-in speakers, USB/HDMI displays, AirPlay 2 receivers (HomePod, Xiaomi Sound, third-party speakers), and other Macs running AirPlay Receiver — with high sync, per-device volume, and a pluggable architecture for future protocols.

**Status**: 🚧 Active development. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Why SyncCast?

macOS has two half-solutions:

1. **Audio MIDI Setup → Multi-Output Device** — works for local outputs, but AirPlay 2 receivers are unreliable and there's no per-device volume.
2. **Control Center AirPlay multi-room** — works for AirPlay 2 receivers only. You lose the local speakers the moment you AirPlay anywhere.

SyncCast unifies both worlds: it captures the system audio stream once and fans it out to every selected device — local *and* AirPlay 2 — with per-device sync compensation and volume.

## Architecture (high level)

```
                ┌──────────────────────────────────────────┐
   Music App  → │      BlackHole 2ch (virtual sink)        │ ← system default output
                └────────────────────┬─────────────────────┘
                                     │  CoreAudio capture
                                     ▼
                ┌──────────────────────────────────────────┐
                │           SyncCast Router (Swift)         │
                │  • Device registry (pluggable transports) │
                │  • Per-device volume + delay alignment    │
                │  • IPC bridge to AirPlay sidecar          │
                └─┬──────────────┬──────────────┬──────────┘
                  │              │              │
         CoreAudio│       CoreAudio│        Unix socket
                  ▼              ▼              ▼
               MBP            Display       ┌─────────────────────┐
              built-in        speakers      │ pyatv sidecar (Py)  │
                                            │  AirPlay 2 RTSP/PTP │
                                            └────────┬────────────┘
                                                     │ AirPlay 2
                                              ┌──────┴──────┐
                                              ▼             ▼
                                          Xiaomi Sound   Mac mini
                                                       (AirPlay Receiver)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design.

## Repo layout

```
syncast/
├── apps/
│   └── menubar/         # SwiftUI menubar app
├── core/
│   ├── router/          # Swift Package: audio capture + routing + transports
│   └── discovery/       # Swift Package: CoreAudio + Bonjour discovery
├── sidecar/             # Python pyatv-based AirPlay 2 multi-target sender
├── proto/               # IPC schemas (JSON-RPC over Unix socket)
├── tools/               # CLI tools (syncast-discover, syncast-route)
├── docs/                # Architecture, ADRs, protocol specs
├── tests/               # Integration + sync-quality harness
└── scripts/             # Build, package, install
```

## Quick start (developers)

```bash
# Clone and build
git clone https://github.com/<your-user>/syncast.git
cd syncast
./scripts/bootstrap.sh   # installs BlackHole + Python deps
./scripts/build.sh       # builds Swift + Python sidecar

# Run
./scripts/dev-run.sh
```

## Roadmap

- [x] P0 — Discovery CLI (CoreAudio + Bonjour)
- [ ] P1 — Local multi-output router with delay compensation
- [ ] P2 — pyatv sidecar (single AirPlay 2 target)
- [ ] P3 — Multi-target AirPlay 2 sync + per-device volume
- [ ] P4 — Swift ↔ Python IPC (Unix socket JSON-RPC)
- [ ] P5 — SwiftUI menubar app ("Whole-house mode")
- [ ] P6 — Packaging, BlackHole bootstrap, first-run wizard

## License

MIT — see [LICENSE](LICENSE).
