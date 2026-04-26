# Round 10 — Hybrid Drift Tracker Validation Protocol

How to validate the Round 10 Hybrid Drift Tracker, interpret the
numbers, and decide whether to ship.

## TL;DR

```bash
bash scripts/drift_test_v2.sh           # default 10 min, 5 s polling
```

Verdict must be **STABLE** to ship. Each run appends one row to
[`round10_drift_history.csv`](round10_drift_history.csv) — the
quarterly-decline tracking spreadsheet.

## Prerequisites

- SyncCast running in **whole-home** mode with at least one device.
- **Hybrid Tracking** enabled
  (`defaults read io.syncast.menubar syncast.hybridTrackingEnabled` == 1).
- A previous full Auto-calibrate run (the tracker uses cached AirPlay τ
  as a prior).
- Music playing — passive correlation needs real audio.

## Thresholds

| Metric              | STABLE   | MARGINAL    | UNSTABLE  |
| :------------------ | :------- | :---------- | :-------- |
| residual_stdev_ms   | ≤ 30     | 30 – 80     | > 80      |
| convergence_s       | < 60     | 60 – 180    | > 180     |
| % time `lost`       | < 5%     | 5 – 15%     | > 15%     |
| % source `passive`  | > 90%    | 50 – 90%    | < 50%     |

`residual_stdev_ms` is the wobble of the fused estimate once locked.
30 ms matches the Haas-effect ceiling for music sync.

## Quarterly targets

The bar tightens each quarter. A regression is any quarter where
residual_stdev_ms goes UP from the previous quarter on the same hardware.

| Quarter | residual_stdev_ms target |
| :------ | :----------------------- |
| Q1      | ≤ 30 (baseline)          |
| Q2      | ≤ 20                     |
| Q3      | ≤ 12                     |
| Q4      | ≤ 8 (single-digit ms)    |

## JSON-RPC contract

The harness polls `/tmp/syncast-<uid>.calibration.sock`.

**Request:** `{"jsonrpc":"2.0","id":1,"method":"tracker.status"}`

**Response (running):**
```json
{"jsonrpc":"2.0","id":1,"result":{
  "timestamp":"2026-04-26T12:34:56.789Z",
  "kalman_offset_ms":2358, "kalman_drift_ppm":4.2,
  "measured_offset_ms":2356, "confidence":0.87,
  "source":"passive", "applied_correction_ms":-2,
  "resulting_delay_ms":1748, "state":"locked"
}}
```

**Response (dormant):** `{"jsonrpc":"2.0","id":1,"result":null}`

**Errors:** `-32601 method not found` (old binary), `-32601 tracker.status
not configured` (provider not wired).

The endpoint is non-disruptive (no audio injected). Polling at 1 Hz is
safe.

## States and sample output

Happy path: `coldStart` → `warm` → `locked`. `drift` is a brief excursion;
`lost` means the tracker gave up and reverted to cached calibration.

```
=== Hybrid Tracker drift_test_v2 summary ===
Duration: 10 min, 120 samples polled (every 5s)
Convergence: locked at t=42s
Residual stability: mean ±18 ms, max ±54 ms (n=118)
State distribution: 84% locked, 8% warm, 5% cold, 3% drift
Source: 96% passive, 4% active probes (5 probes total)
Total correction: 287 ms across 118 ticks (avg 2.43 ms/tick)
Verdict: STABLE — within ±30 ms target
```

## Troubleshooting

- **`calibration socket not found`** — SyncCast not in whole-home mode.
- **`Hybrid Tracking is not enabled`** — flip the menubar toggle (or
  `defaults write io.syncast.menubar syncast.hybridTrackingEnabled -bool true`)
  + restart.
- **`NO_DATA`** — socket responds but tracker emits no samples. Check
  cached calibration + that music is playing.
- **Locked but high stdev** — Kalman R too low (over-trusting noisy
  measurements), mic reflections, or active probe hit a destructive-
  interference null. Inspect CSV's `confidence` and `kalman_drift_ppm`.

## Long soak

`bash scripts/drift_test_v2.sh 180 30` (3 h, 30 s polling). Run once per
release cycle to catch thermal drift, network changes, sleep/wake.
