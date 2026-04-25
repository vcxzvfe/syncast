# ADR-004: Pad-the-fast-path sync

**Status**: Accepted · 2026-04-25

## Context

We must align the ~12 ms local CoreAudio path with the ~1.8 s AirPlay 2 path inside a 30 ms perceptual budget. Surveyed prior art (Snapcast, Roon/RAAT, Sonos, Squeezebox, AirPlay 2's own PTP) — see `docs/research/sync-brief.md`.

## Decision

- **Pad the fast path.** Treat the slowest enabled device's end-to-end latency as the master target `T_master`. Every other device is delayed by `T_master − L_i` so all devices emit the same captured audio at the same wall-clock instant.
- **Master clock**: `mach_absolute_time()` on the host. No NTP discipline required.
- **Drift**: a slow PI loop on each local AUHAL inserts or drops one sample per ~30 s when its buffer-fill diverges from target. Imperceptible.
- **Calibration**: tap-along click train (no microphone needed) by default; optional acoustic-loopback "precision mode" using the Mac's mic for ±5 ms accuracy.

## Rationale

- Speeding up the slow path is impossible — we can't make AirPlay deliver faster than ~1.5 s. So the only path to coherence is delaying the fast path.
- Sample-level inter-device sync within local outputs comes for free from the shared Mac clock; cross-clock-domain drift only matters between Mac local and AirPlay. The PI loop handles it without ASRC.
- A microphone-free calibration UX is essential: most users don't want to wave their phone around to set this up. ±15 ms tap-along accuracy is good enough for music; the mic mode is opt-in for users who want sub-30 ms.

## Consequences

- "Whole-house mode" introduces ~2 s of pipeline latency. Acceptable for music, **not** acceptable for video — we surface a warning when video apps are foregrounded.
- The scheduler must re-plan when AirPlay receivers come and go (`T_master` changes). It does so atomically by snapshotting the current plan and only swapping when all consumers have caught up.
- Manual per-device trim (`±2000 ms`) is exposed in the UI for users with quirky receivers.

## Alternatives considered

- **Pull the slow path forward** (impossible).
- **PTPv2 across the LAN** — would require running our own PTP daemon and devices that respect it. Out of scope.
- **Buffer-only sync** (no per-device trim) — fails for AirPlay receivers that report wrong latency.
