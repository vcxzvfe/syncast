#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import passive_baseline_store as pbs


def _row(
    index: int,
    delay: float,
    *,
    context: str = "ctx-a",
    sync_state: str = "suspect",
    sync_revision: int = 7,
    multi_path_delta_ms: float | None = None,
) -> dict:
    paths = [
        {
            "delay_ms": delay,
            "window_fraction": 1.0,
            "mean_score": 0.8,
        }
    ]
    strong = {
        "count": 1,
        "spread_ms": 0,
        "delays_ms": [delay],
    }
    if multi_path_delta_ms is not None:
        paths.append(
            {
                "delay_ms": delay + multi_path_delta_ms,
                "window_fraction": 0.8,
                "mean_score": 0.6,
            }
        )
        strong = {
            "count": 2,
            "spread_ms": multi_path_delta_ms,
            "delays_ms": [delay, delay + multi_path_delta_ms],
        }
    return {
        "index": index,
        "verdict": "accepted",
        "delay_ms": delay,
        "current_delay_ms": 2200,
        "delay_locked": False,
        "context_signature": context,
        "enabled_airplay_count": 1,
        "active_airplay_count": 1,
        "airplay_timing_epoch": 1,
        "sync_context_state": sync_state,
        "sync_context_revision": sync_revision,
        "capture_backend": "tap",
        "sample": {
            "cycles": [
                {
                    "index": 1,
                    "capture": {
                        "sampleRate": 48000,
                        "microphoneFrames": 100,
                        "microphoneArmedAtNs": 1_000_000_000,
                        "microphoneFirstSampleAtNs": 1_000_000_000,
                        "microphoneStartPaddingFrames": 0,
                        "microphoneWarmupFramesDropped": 128,
                        "airplayTimingEpoch": 1,
                        "endAirplayTimingEpoch": 1,
                        "syncContextState": sync_state,
                        "syncContextRevision": sync_revision,
                        "endSyncContextState": sync_state,
                        "endSyncContextRevision": sync_revision,
                    },
                    "estimate": {
                        "path_candidates": paths
                    },
                    "strong_peaks": strong,
                }
            ]
        },
    }


def _monitor(
    delays=(2300.0, 2302.0, 2298.0),
    *,
    context="ctx-a",
    sync_state: str = "suspect",
    sync_revision: int = 7,
    multi_path_delta_ms: float | None = None,
) -> dict:
    rows = [
        _row(
            index,
            delay,
            context=context,
            sync_state=sync_state,
            sync_revision=sync_revision,
            multi_path_delta_ms=multi_path_delta_ms,
        )
        for index, delay in enumerate(delays, 1)
    ]
    return {
        "summary": {
            "verdict": "stable",
            "reason": None,
            "samples_total": len(rows),
            "samples_accepted": len(rows),
            "required_accepted": 2,
            "delay_range_ms": max(delays) - min(delays),
            "delay_end_to_start_ms": delays[-1] - delays[0],
            "trailing_inconclusive_samples": 0,
            "context_gate": None,
        },
        "rows": rows,
    }


def _summary() -> dict:
    return {
        "monitor_verdict": "stable",
        "sample_verdict_counts": {"accepted": 3},
        "samples_total": 3,
        "strong_peak_flag_count": 0,
        "multi_path_candidate_flag_count": 0,
    }


def _summary_for_monitor(monitor: dict) -> dict:
    multipath = 0
    strong = 0
    for row in monitor["rows"]:
        for cycle in row.get("sample", {}).get("cycles", []):
            paths = cycle.get("estimate", {}).get("path_candidates", [])
            if len(paths) >= 2:
                multipath += 1
            if int(cycle.get("strong_peaks", {}).get("count") or 0) >= 2:
                strong += 1
    result = _summary()
    result["strong_peak_flag_count"] = strong
    result["multi_path_candidate_flag_count"] = multipath
    return result


def _write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n")


def _session(
    root: Path,
    monitor: dict | None = None,
    *,
    decision: dict | None = None,
) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    monitor = monitor or _monitor()
    _write_json(
        root / "manifest.json",
        {
            "schema": "syncast.passive_drift_session.v1",
            "emitsAudio": False,
            "appliesDelay": False,
            "opensMicrophoneOnlyAfterPreflight": True,
        },
    )
    _write_json(root / "preflight.json", {"verdict": "preflight_ok"})
    _write_json(root / "monitor.json", monitor)
    _write_json(root / "summary.json", _summary_for_monitor(monitor))
    _write_json(
        root / "decision.json",
        decision
        or {
            "verdict": "initialize_baseline",
            "auto_apply_eligible": False,
            "baseline_offset_ms": 100.0,
            "features": {
                "context_signature": "ctx-a",
                "capture_backend": "tap",
                "delay_locked": False,
                "enabled_airplay_count": 1,
                "active_airplay_count": 1,
                "airplay_timing_epoch": 1,
                "sync_context_state": "suspect",
                "sync_context_revision": 7,
            },
        },
    )
    _write_jsonl(root / "samples.jsonl", monitor["rows"])
    return root


class PassiveBaselineStoreTests(unittest.TestCase):
    def test_record_baseline_from_ready_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp) / "session")
            store = Path(tmp) / "baselines.json"
            result = pbs.record_baseline(store, root)
            payload = json.loads(store.read_text())
        self.assertEqual(result["verdict"], "recorded")
        self.assertEqual(payload["schema"], pbs.STORE_SCHEMA)
        self.assertEqual(len(payload["baselines"]), 1)
        baseline = next(iter(payload["baselines"].values()))
        self.assertEqual(baseline["baselineOffsetMs"], 100.0)
        self.assertFalse(baseline["delayLocked"])
        self.assertFalse(baseline["emitsAudio"])
        self.assertFalse(baseline["appliesDelay"])

    def test_decide_with_store_recommends_from_matching_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            baseline_root = Path(tmp) / "baseline"
            current_root = Path(tmp) / "current"
            baseline_root.mkdir()
            current_root.mkdir()
            _session(baseline_root, _monitor(delays=(2300.0, 2302.0, 2298.0)))
            _session(
                current_root,
                _monitor(
                    delays=(2318.0, 2320.0, 2316.0),
                    sync_state="valid",
                    sync_revision=8,
                ),
            )
            store = Path(tmp) / "baselines.json"
            pbs.record_baseline(store, baseline_root)
            result = pbs.decide_with_store(store, current_root)
        self.assertEqual(result["verdict"], "decided")
        self.assertEqual(result["decision"]["verdict"], "recommend")
        self.assertEqual(result["decision"]["recommended_delay_ms"], 2218)

    def test_decide_with_store_reuses_baseline_after_sync_context_mark(self):
        with tempfile.TemporaryDirectory() as tmp:
            baseline_root = Path(tmp) / "baseline"
            current_root = Path(tmp) / "current"
            baseline_root.mkdir()
            current_root.mkdir()
            _session(
                baseline_root,
                _monitor(
                    delays=(2300.0, 2302.0, 2298.0),
                    sync_state="suspect",
                    sync_revision=7,
                ),
            )
            _session(
                current_root,
                _monitor(
                    delays=(2318.0, 2320.0, 2316.0),
                    sync_state="valid",
                    sync_revision=8,
                ),
            )
            store = Path(tmp) / "baselines.json"
            pbs.record_baseline(store, baseline_root)
            result = pbs.decide_with_store(store, current_root)
        self.assertEqual(result["verdict"], "decided")
        self.assertEqual(result["baseline"]["syncContextState"], "suspect")
        self.assertEqual(result["baseline"]["syncContextRevision"], 7)
        self.assertEqual(
            result["decision"]["features"]["sync_context_state"],
            "valid",
        )
        self.assertEqual(result["decision"]["features"]["sync_context_revision"], 8)
        self.assertEqual(result["decision"]["recommended_delay_ms"], 2218)

    def test_decide_with_store_uses_latest_legacy_identity_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            current_root = Path(tmp) / "current"
            current_root.mkdir()
            _session(
                current_root,
                _monitor(
                    delays=(2318.0, 2320.0, 2316.0),
                    sync_state="valid",
                    sync_revision=8,
                ),
            )
            old_baseline = {
                "key": "legacy-suspect",
                "createdUnix": 1.0,
                "updatedUnix": 1.0,
                "sessionRoot": "/tmp/old",
                "contextSignature": "ctx-a",
                "captureBackend": "tap",
                "delayLocked": False,
                "enabledAirplayCount": 1,
                "activeAirplayCount": 1,
                "airplayTimingEpoch": 1,
                "syncContextState": "suspect",
                "syncContextRevision": 7,
                "baselineOffsetMs": 82.0,
            }
            latest_baseline = {
                **old_baseline,
                "key": "legacy-valid",
                "createdUnix": 2.0,
                "updatedUnix": 2.0,
                "sessionRoot": "/tmp/latest",
                "syncContextState": "valid",
                "syncContextRevision": 8,
                "baselineOffsetMs": 100.0,
            }
            store = Path(tmp) / "baselines.json"
            _write_json(
                store,
                {
                    "schema": pbs.STORE_SCHEMA,
                    "baselines": {
                        old_baseline["key"]: old_baseline,
                        latest_baseline["key"]: latest_baseline,
                    },
                },
            )
            result = pbs.decide_with_store(store, current_root)
        self.assertEqual(result["baseline"]["key"], "legacy-valid")
        self.assertEqual(result["decision"]["recommended_delay_ms"], 2218)

    def test_missing_baseline_is_not_applicable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "current"
            root.mkdir()
            _session(root, _monitor(context="ctx-b"))
            store = Path(tmp) / "baselines.json"
            with self.assertRaisesRegex(Exception, "no passive baseline"):
                pbs.decide_with_store(store, root)

    def test_decide_with_store_requires_stored_baseline_for_path_pair_correction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "current"
            root.mkdir()
            monitor = _monitor(multi_path_delta_ms=18.0)
            _session(
                root,
                monitor,
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2218,
                    "decision_basis": "coherent_path_pair_relative",
                    "reason": "coherent path-pair",
                },
            )
            with self.assertRaisesRegex(Exception, "no passive baseline"):
                pbs.decide_with_store(Path(tmp) / "baselines.json", root)

    def test_decide_with_store_uses_stored_path_pair_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            baseline_root = Path(tmp) / "baseline"
            current_root = Path(tmp) / "current"
            baseline_root.mkdir()
            current_root.mkdir()
            _session(
                baseline_root,
                _monitor(multi_path_delta_ms=3.0),
                decision={
                    "verdict": "initialize_baseline",
                    "auto_apply_eligible": False,
                    "baseline_offset_ms": 100.0,
                    "baseline_path_pair_delta_ms": 3.0,
                    "decision_basis": "coherent_path_pair_aligned_baseline",
                    "features": {
                        "context_signature": "ctx-a",
                        "capture_backend": "tap",
                        "delay_locked": False,
                        "enabled_airplay_count": 1,
                        "active_airplay_count": 1,
                        "airplay_timing_epoch": 1,
                        "sync_context_state": "suspect",
                        "sync_context_revision": 7,
                    },
                },
            )
            _session(
                current_root,
                _monitor(
                    multi_path_delta_ms=18.0,
                    sync_state="valid",
                    sync_revision=8,
                ),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2215,
                    "decision_basis": "coherent_path_pair_relative",
                    "features": {
                        "context_signature": "ctx-a",
                        "capture_backend": "tap",
                        "delay_locked": False,
                        "enabled_airplay_count": 1,
                        "active_airplay_count": 1,
                        "airplay_timing_epoch": 1,
                        "sync_context_state": "valid",
                        "sync_context_revision": 8,
                    },
                },
            )
            store = Path(tmp) / "baselines.json"
            pbs.record_baseline(store, baseline_root)
            result = pbs.decide_with_store(store, current_root)
        self.assertEqual(result["verdict"], "decided")
        self.assertEqual(result["baseline"]["baselinePathPairDeltaMs"], 3.0)
        self.assertEqual(result["decision"]["decision_basis"], "coherent_path_pair_relative")
        self.assertEqual(result["decision"]["raw_correction_ms"], 15.0)
        self.assertEqual(result["decision"]["recommended_delay_ms"], 2215)

    def test_decide_with_store_rejects_path_pair_against_legacy_single_path_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            baseline_root = Path(tmp) / "baseline"
            current_root = Path(tmp) / "current"
            baseline_root.mkdir()
            current_root.mkdir()
            _session(baseline_root, _monitor(delays=(2300.0, 2302.0, 2298.0)))
            _session(
                current_root,
                _monitor(
                    multi_path_delta_ms=18.0,
                    sync_state="valid",
                    sync_revision=8,
                ),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2218,
                    "decision_basis": "coherent_path_pair_relative",
                },
            )
            store = Path(tmp) / "baselines.json"
            pbs.record_baseline(store, baseline_root)
            with self.assertRaisesRegex(Exception, "lacks Local/AirPlay path-pair"):
                pbs.decide_with_store(store, current_root)

    def test_record_rejects_session_without_safety_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "session"
            root.mkdir()
            _session(root)
            _write_json(
                root / "manifest.json",
                {
                    "schema": "syncast.passive_drift_session.v1",
                    "emitsAudio": True,
                    "appliesDelay": False,
                    "opensMicrophoneOnlyAfterPreflight": True,
                },
            )
            with self.assertRaisesRegex(Exception, "not usable"):
                pbs.record_baseline(Path(tmp) / "baselines.json", root)

    def test_main_record_writes_store(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "session"
            root.mkdir()
            _session(root)
            store = Path(tmp) / "baselines.json"
            old_parse = pbs._parse_args
            try:
                pbs._parse_args = lambda: type(
                    "Args",
                    (),
                    {
                        "command": "record",
                        "store": store,
                        "session_root": root,
                    },
                )()
                with mock.patch.object(sys, "stdout"):
                    rc = pbs.main()
            finally:
                pbs._parse_args = old_parse
            self.assertEqual(rc, pbs.EXIT_OK)
            self.assertTrue(store.exists())


if __name__ == "__main__":
    unittest.main()
