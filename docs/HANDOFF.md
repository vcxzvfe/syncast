# SyncCast — Handoff Document

> **Last updated**: 2026-04-25 13:20 (local) · **For**: next-session resumption
> **Status of work**: ~90% done. Local audio works end-to-end. AirPlay path
> proven working live (Xiaomi Sound played for 18+ seconds in a test) but
> regresses after re-run. Local multi-output sync deployed but unverified.

---

## 1. What works (verified live by user)

- ✅ **MBP built-in speaker** — captures system audio via SCK and plays back through AUHAL. User confirmed audible.
- ✅ **Test tone** through AUHAL on MBP speaker (440 Hz at 0.2 amplitude). User confirmed audible. Proves `AUHAL → device` path is correct.
- ✅ **Xiaomi Sound via AirPlay 2** — verified at 13:11 local. OwnTone player state went to `play`, progress advanced 18+ seconds, AudioSocketWriter sent 1302 packets linearly at ~100 pkts/sec.
- ✅ **8 devices discovered** by Bonjour + CoreAudio enumeration (Xiaomi, Mac mini, Zifan的MacBook Pro AirPlay receiver, PG27UCDM, BlackHole, MBP扬声器, Microsoft Teams Audio, 多输出设备).
- ✅ **Screen Recording TCC stable across rebuilds** via `SyncCast Dev` self-signed cert (created automatically by `scripts/create-dev-cert` style flow — already in user's keychain).
- ✅ **`.app` bundle** at `/Applications/SyncCast.app` — 53 MB, includes Swift menubar + Python sidecar + OwnTone + 38 dylibs.

## 2. What user observed broken (last test before handoff)

After autonomous fixes:
- **MBP speaker** played
- **Xiaomi Sound** silent
- **PG27UCDM (display)** silent
- Local sync between MBP + PG27UCDM was previously audibly off (delay/echo) — fix deployed but unverified

## 3. Current snapshot (when this doc was written)

```
Processes:
  54684  /Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar
  54686  syncast-sidecar (PyInstaller parent)
  54687  syncast-sidecar (PyInstaller child)
  ❌ OwnTone is DEAD — REST returns empty, no /owntone/owntone process

Sockets:
  /tmp/syncast-501.sock         (control, sidecar)
  /tmp/syncast-501.audio.sock   (PCM, may be stale)

Latest SCK report shows ring is being filled (seen=20729 ≈ 200s of audio
captured) but NO render[] entries (no LocalOutput open) and NO
airplayWriter entries (no AirPlay stream active). This means the engine
was either stopped by a toggle-off or never re-started after some
internal failure.
```

## 4. The 7 bugs that were fixed (commit `463bb28`)

These are the diagnoses that took ~30 min of intense debugging at the end. See the commit message for details.

| # | File | Symptom | Root cause |
|---|---|---|---|
| 1 | `IpcClient.swift` | `device.add` IPC hangs forever | `pending[id]=cont` registered AFTER write; fast Unix-socket replies got dropped |
| 2 | `audio_socket.py`, `AudioSocketWriter.swift` | `[Errno 43] Protocol not supported` | macOS Unix sockets don't support `SOCK_SEQPACKET` — must use `SOCK_STREAM` |
| 3 | `package-app.sh` (`@executable_path/../../Frameworks`) | `dyld: Library not loaded: @executable_path/../Frameworks/libavfilter.11.dylib` | OwnTone binary lives in `Resources/owntone/`, so `..` resolves to `Resources/`, not `Contents/`. Need `../..` |
| 4 | `owntone_backend.py` `_write_config` | `config: Could not lookup user "501"` + `no such option 'filepath_pattern'` | OwnTone uses `getpwnam` not `getpwuid`; `filepath_pattern` is invalid |
| 5 | `owntone_backend.py` `play_pipe` | `HTTP 400 POST /api/queue/items/add` | URIs must be query string `?uris=library:track:N`, not JSON body |
| 6 | `owntone_backend.py` `set_output_volume` | `HTTP 400 PUT /api/outputs/{id}/volume` | Wrong endpoint; correct is `PUT /api/outputs/{id}` body `{"volume":N}` |
| 7 | `AudioSocketWriter.swift` `start()` | "exactly 68 packets sent then stuck forever" | `start()` not idempotent; double-call from `pushAirplayState` raced fd |

Plus a separate fix in `AppModel.reconcileEngineAsync`:
- Push routing to Router (`setRouting` + `enable`) BEFORE `router.start(devices:)` — otherwise Router.start sees empty routing and skips creating any AUHAL
- Push AirPlay state BEFORE awaiting SCK start — so AirPlay can run independently of SCK readiness

## 5. Multi-output sync (Problem A) — fix deployed, NOT verified

**The bug**: When MBP扬声器 + PG27UCDM are both enabled, the user reported audible delay between them ("听上去很乱").

**The fix** in `LocalOutput.swift`:
- Added `static var deviceLatencyFramesByDevID: [String: Int64]` shared across all LocalOutput instances
- `start()` queries `kAudioDevicePropertyLatency + kAudioDevicePropertySafetyOffset + kAudioStreamPropertyLatency` and stores total
- `render()` finds the max latency in the dict, then `startFrame = writePos - baselineFrames(2400) - (maxLatency - myLatency) - frames`
- "Pad-the-fast-path" — fast device waits for slowest

**To verify**: run with `SYNCAST_AUTO_TEST=mbp,display`, play music, listen to whether MBP + PG27UCDM are now in sync.

## 6. AirPlay 2 (Problem B) — works once, regresses

**Critical insight from final test**: After all 7 fixes, AirPlay DID work for 18+ seconds (Xiaomi played `say` voice). Then it went silent again.

**Likely remaining issues**:
1. **OwnTone may be crashing** between toggles. Check `owntone.log` at `~/Library/Application Support/SyncCast/owntone/owntone.log` for FATAL after Xiaomi disconnect.
2. **Xiaomi RTSP timeout**: OwnTone log showed `airplay: Device 'Xiaomi Sound-6853' closed RTSP connection` once. Xiaomi may close RTSP if buffer underrun happens. Need keep-alive or auto-reconnect logic.
3. **Sample rate mismatch**: We send 48 kHz s16 PCM. OwnTone's pipe input expects 44.1 kHz (or maybe handles 48). May cause subtle issues over long runs.

## 7. How to resume in a new conversation

### State on disk (what's already done):
- All code committed and pushed: latest commit `463bb28` on https://github.com/vcxzvfe/syncast
- `.app` at `/Applications/SyncCast.app` (signed with `SyncCast Dev` cert)
- `SyncCast Dev` cert lives in `~/Library/Keychains/login.keychain-db` (already trusted)
- TCC: Screen Recording granted to `io.syncast.menubar`
- BlackHole 2ch installed (system-wide, in `/Library/Audio/Plug-Ins/HAL/`)
- OwnTone built from source at `~/owntone_data/usr/sbin/owntone` (also bundled into .app)
- All build deps via Homebrew

### To resume:
1. Open new Claude conversation
2. Paste this prompt:

```
I'm resuming work on SyncCast — a macOS open-source app that captures
system audio and synchronously plays it across local CoreAudio outputs
(MBP speaker, display) AND AirPlay 2 receivers (Xiaomi Sound, Mac mini)
via OwnTone.

Repo: https://github.com/vcxzvfe/syncast (latest commit 463bb28)
Local checkout: /Users/zifan/syncast/
App bundle: /Applications/SyncCast.app/

Read /Users/zifan/syncast/docs/HANDOFF.md for the full state.

Current symptom: after my fixes, MBP speaker plays correctly, but
Xiaomi Sound and PG27UCDM display speaker fall silent within seconds.
OwnTone may be crashing between toggles.

Continue debugging from where we left off. Focus areas:
1. Why OwnTone dies after 1-2 minutes of streaming (check
   ~/Library/Application Support/SyncCast/owntone/owntone.log)
2. Whether the multi-output sync fix in LocalOutput.swift actually
   removes the audible delay between MBP and PG27UCDM
3. Stability across multiple toggle on/off cycles
```

3. The new agent will read the handoff doc and continue. Codex CLI is already logged in.

### Quick smoke test to confirm everything is still good:

```bash
# Restart cleanly
pkill -9 -f SyncCastMenuBar 2>/dev/null
pkill -9 -f syncast-sidecar 2>/dev/null
pkill -9 -f /owntone/owntone 2>/dev/null
sleep 1
rm -f /tmp/syncast-501.sock /tmp/syncast-501.audio.sock
rm -f ~/Library/Logs/SyncCast/launch.log
rm -f "$HOME/Library/Application Support/SyncCast/owntone/owntone.conf"

# Launch with auto-test (both MBP + Xiaomi enabled 4s after launch)
SYNCAST_AUTO_TEST=mbp,xiaomi /Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar > /tmp/sc-stderr.log 2>&1 &

# Play music in NeteaseMusic / Music.app (system output stays as BlackHole)

# Verify within 30s:
curl -s http://127.0.0.1:3689/api/player | python3 -m json.tool
# Should show state=play with progress increasing

curl -s http://127.0.0.1:3689/api/outputs | python3 -m json.tool
# Xiaomi should be selected=true

tail -5 ~/Library/Logs/SyncCast/launch.log | grep 'SCK report'
# Should show: pkts/bytes increasing linearly (~100 pkts/sec)
```

## 8. File map (recently changed)

```
apps/menubar/Sources/SyncCastMenuBar/
  ├── AppModel.swift          ← reconcile order, AirPlay-before-SCK, AUTO_TEST flag
  ├── SidecarLauncher.swift   ← spawns sidecar + waits for socket
  ├── SyncCastApp.swift       ← TCC bootstrap + file logger
  └── MainPopover.swift       ← UI (whole-row tap, debug strip, no-ScrollView)

core/router/Sources/SyncCastRouter/
  ├── Router.swift            ← syncLocalOutputs, registerAirplayDevice, setActiveAirplayDevices
  ├── RingBuffer.swift        ← lock-free SPMC ring (atomic via SyncCastAtomic.h)
  ├── SCKCapture.swift        ← ScreenCaptureKit capture, ABL probe, fast-path memcpy
  ├── LocalOutput.swift       ← AUHAL with hardware-latency compensation
  ├── AudioSocketWriter.swift ← idempotent start, SOCK_STREAM
  ├── IpcClient.swift         ← off-actor read thread, race-fixed continuation
  ├── ScreenRecordingTCC.swift
  ├── Capture.swift           ← legacy BlackHole IOProc (unused but kept)
  ├── Scheduler.swift, Clock.swift, RouterTypes.swift
  └── Sources/SyncCastAtomic/ (C bridging for atomics)

sidecar/src/syncast_sidecar/
  ├── server.py               ← JSON-RPC + writer.drain
  ├── device_manager.py       ← _reconcile_outputs by name
  ├── owntone_backend.py      ← spawn owntone, REST client, FIFO writer
  ├── audio_socket.py         ← SOCK_STREAM listener → FIFO sink
  └── jsonrpc.py, log.py, __main__.py

scripts/
  ├── package-app.sh          ← @executable_path/../../Frameworks for owntone
  ├── install-app.sh          ← deploy to /Applications + re-sign
  ├── _bundle-dylibs.sh       ← bash 3.2-compat dylib closure walker
  ├── build-owntone.sh        ← from-source on macOS Tahoe
  └── bootstrap.sh

docs/research/
  ├── coreaudio-brief.md, airplay2-brief.md, sync-brief.md, ux-brief.md
  ├── screencapturekit-brief.md   ← SCK pivot
  ├── blackhole-hal-tcc-tahoe.md  ← why HAL doesn't work
  └── tahoe-screencap-tcc-stuck.md ← why ad-hoc fails TCC
```

## 9. Diagnostic tools available

- `~/Library/Logs/SyncCast/launch.log` — Swift-side bootstrap + reconcile + SCK reports
- `/tmp/sc-stderr.log` — sidecar JSON logs (when launched from CLI)
- `~/Library/Application Support/SyncCast/owntone/owntone.log` — OwnTone's own log
- `codex exec --skip-git-repo-check "..."` — second-opinion code review

## 10. Known unresolved issues

- **OwnTone crash recovery**: when OwnTone dies, sidecar's `_owntone` reference is stale. Next stream.start fails. Need health check + auto-restart.
- **AudioSocketWriter rate**: sends 100 pkts/sec at 48 kHz, but OwnTone pipe input expects 44.1 kHz. May need resample on Swift side.
- **Settings + Calibrate buttons** in MainPopover footer are still stubs (`action: {}`).
- **AirPlay receiver pairing**: HomePods may need PIN. Not handled.
- **No persistence**: device toggles don't survive app restart.
- **AUHAL self-feedback potential**: SCK with `excludesCurrentProcessAudio=true` mostly excludes our AUHAL output but the brief notes this is unreliable. Migration to AVAudioEngine is the v2 fix.
