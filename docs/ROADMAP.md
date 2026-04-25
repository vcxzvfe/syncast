# SyncCast Roadmap

> Phase status and tracking. Anything not on this page hasn't been committed to.

## Done
- [x] Repo skeleton, license, .gitignore, directory layout
- [x] Research briefs: CoreAudio, AirPlay 2, sync algorithms, UX (`docs/research/`)
- [x] ADR-001 through ADR-006 architecture decisions
- [x] **P0 Discovery**: `core/discovery` Swift Package — CoreAudio + Bonjour, stable IDs, AsyncStream events
- [x] **P0 CLI**: `tools/syncast-discover` — list devices, watch mode, JSON output
- [x] **P1 Capture & ring**: BlackHole IOProc capture + lock-free ring buffer + scheduler ("pad-the-fast-path")
- [x] **P1 Local fan-out**: AUHAL per output, per-device gain & delay
- [x] **IPC schema**: JSON-RPC 2.0 over Unix socket + SOCK_SEQPACKET audio socket
- [x] **Sidecar skeleton**: Python control server, JSON-RPC plumbing, OwnTone REST/FIFO backend stub
- [x] **P5 UI shell**: SwiftUI menubar app — popover, whole-house toggle, device rows with volume sliders

## In progress
- [ ] **P2 Streaming end-to-end**: wire audio_socket → OwnTone FIFO; verify a single AirPlay 2 receiver receives audio
- [ ] **P3 Sync calibration**: tap-along click train UX + wall-clock-anchor RTSP-derived latency probe
- [ ] **P4 IPC client**: hook `IpcClient` into `Router`, spawn the sidecar from the menubar app

## Next (post-P3)
- [ ] **P6 Packaging**: `.app` bundle, PyInstaller for sidecar, OwnTone embedded, BlackHole bootstrap, notarization
- [ ] **First-run wizard**: 5 screens (welcome → BlackHole → default-output → AirPlay scan → calibrate)
- [ ] **Persistence**: `~/Library/Application Support/SyncCast/devices.json`
- [ ] **Drift PI loop**: ±1 sample insert/drop in AUHAL render
- [ ] **Robustness**: sidecar restart on crash with backoff, network-loss recovery

## Future
- [ ] **Snapcast transport** (`transport: "snapcast"`)
- [ ] **Generic RTP transport** for Linux receivers
- [ ] **ScreenCaptureKit** to remove BlackHole dependency on Sequoia+
- [ ] **Native Swift AirPlay 2 sender** (replace OwnTone) — multi-month effort
- [ ] **Multi-zone** (different streams to different rooms) — explicit non-goal for v1

## Open questions / risks
- **OwnTone macOS Homebrew formula**: confirm the brew formula is current and `pipe://` input works. Fallback: build from source via the repo's macOS instructions.
- **AirPlay receiver pairing**: HomePods often need a one-time PIN pair. UX flow TBD.
- **Notarization**: the OwnTone binary needs to be co-signed; investigate.
