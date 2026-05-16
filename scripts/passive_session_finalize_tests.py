#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import passive_session_finalize as psf


def _row(
    index: int,
    delay: float,
    *,
    context: str = "ctx-a",
    sync_state: str = "suspect",
    sync_revision: int = 7,
) -> dict:
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
                        "path_candidates": [
                            {
                                "delay_ms": delay,
                                "window_fraction": 1.0,
                                "mean_score": 0.8,
                            }
                        ]
                    },
                    "strong_peaks": {
                        "count": 1,
                        "spread_ms": 0,
                        "delays_ms": [delay],
                    },
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
) -> dict:
    rows = [
        _row(
            index,
            delay,
            context=context,
            sync_state=sync_state,
            sync_revision=sync_revision,
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


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n")


def _session(root: Path, monitor: dict | None = None) -> Path:
    monitor = monitor or _monitor()
    root.mkdir(parents=True, exist_ok=True)
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
    _write_json(
        root / "summary.json",
        {
            "monitor_verdict": "stable",
            "sample_verdict_counts": {"accepted": 3},
            "samples_total": 3,
            "strong_peak_flag_count": 0,
            "multi_path_candidate_flag_count": 0,
        },
    )
    _write_json(
        root / "decision.json",
        {
            "verdict": "initialize_baseline",
            "auto_apply_eligible": False,
            "baseline_offset_ms": 100.0,
        },
    )
    _write_jsonl(root / "samples.jsonl", monitor["rows"])
    return root


class PassiveSessionFinalizeTests(unittest.TestCase):
    def test_auto_records_when_no_baseline_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp) / "session")
            store = Path(tmp) / "store.json"
            result = psf.finalize_session(
                session_root=root,
                store_path=store,
                mode="auto",
            )
            payload = json.loads(store.read_text())
        self.assertEqual(result["verdict"], "recorded")
        self.assertEqual(len(payload["baselines"]), 1)
        self.assertFalse(result["appliesDelay"])

    def test_auto_decides_when_matching_baseline_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            baseline = _session(Path(tmp) / "baseline")
            current = _session(
                Path(tmp) / "current",
                _monitor(
                    delays=(2318.0, 2320.0, 2316.0),
                    sync_state="valid",
                    sync_revision=8,
                ),
            )
            store = Path(tmp) / "store.json"
            psf.finalize_session(session_root=baseline, store_path=store, mode="auto")
            result = psf.finalize_session(session_root=current, store_path=store, mode="auto")
        self.assertEqual(result["verdict"], "decided")
        self.assertEqual(result["result"]["decision"]["verdict"], "recommend")
        self.assertEqual(result["result"]["decision"]["recommended_delay_ms"], 2218)

    def test_auto_decides_after_baseline_mark_changes_sync_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            baseline = _session(
                Path(tmp) / "baseline",
                _monitor(
                    delays=(2300.0, 2302.0, 2298.0),
                    sync_state="suspect",
                    sync_revision=7,
                ),
            )
            current = _session(
                Path(tmp) / "current",
                _monitor(
                    delays=(2318.0, 2320.0, 2316.0),
                    sync_state="valid",
                    sync_revision=8,
                ),
            )
            store = Path(tmp) / "store.json"
            psf.finalize_session(session_root=baseline, store_path=store, mode="auto")
            result = psf.finalize_session(session_root=current, store_path=store, mode="auto")
        self.assertEqual(result["verdict"], "decided")
        self.assertEqual(result["result"]["baseline"]["syncContextState"], "suspect")
        self.assertEqual(
            result["result"]["decision"]["features"]["sync_context_state"],
            "valid",
        )
        self.assertEqual(
            result["result"]["decision"]["features"]["sync_context_revision"],
            8,
        )

    def test_decide_mode_requires_existing_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp) / "session")
            with self.assertRaisesRegex(Exception, "no passive baseline"):
                psf.finalize_session(
                    session_root=root,
                    store_path=Path(tmp) / "store.json",
                    mode="decide",
                )

    def test_capture_failed_session_not_applicable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "session"
            root.mkdir()
            _write_json(
                root / "manifest.json",
                {
                    "schema": "syncast.passive_drift_session.v1",
                    "emitsAudio": False,
                    "appliesDelay": False,
                    "opensMicrophoneOnlyAfterPreflight": True,
                },
            )
            _write_json(
                root / "preflight.json",
                {"summary": {"verdict": "capture_failed", "reason": "socket blocked"}},
            )
            with self.assertRaisesRegex(Exception, "capture failed"):
                psf.finalize_session(
                    session_root=root,
                    store_path=Path(tmp) / "store.json",
                    mode="auto",
                )

    def test_main_writes_output_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp) / "session")
            store = Path(tmp) / "store.json"
            output = Path(tmp) / "finalize.json"
            old_parse = psf._parse_args
            try:
                psf._parse_args = lambda: type(
                    "Args",
                    (),
                    {
                        "session_root": root,
                        "store": store,
                        "mode": "auto",
                        "output": output,
                    },
                )()
                with mock.patch.object(sys, "stdout"):
                    rc = psf.main()
            finally:
                psf._parse_args = old_parse
            self.assertEqual(rc, psf.EXIT_OK)
            self.assertEqual(json.loads(output.read_text())["verdict"], "recorded")


if __name__ == "__main__":
    unittest.main()
