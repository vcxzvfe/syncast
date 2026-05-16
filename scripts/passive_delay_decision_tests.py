#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import passive_delay_decision as pdd


def _cycle(
    delay_ms: float,
    *,
    multi_path: bool = False,
    multi_path_delta_ms: float = 75.0,
) -> dict:
    paths = [{"delay_ms": delay_ms, "window_fraction": 1.0, "mean_score": 0.8}]
    strong = {"count": 1, "spread_ms": 0.0, "delays_ms": [delay_ms]}
    if multi_path:
        paths.append(
            {
                "delay_ms": delay_ms + multi_path_delta_ms,
                "window_fraction": 0.8,
                "mean_score": 0.6,
            }
        )
        strong = {
            "count": 2,
            "spread_ms": multi_path_delta_ms,
            "delays_ms": [delay_ms, delay_ms + multi_path_delta_ms],
        }
    return {
        "index": 1,
        "estimate": {"path_candidates": paths},
        "strong_peaks": strong,
    }


def _payload(
    *,
    verdict: str = "stable",
    current_delay_ms: float = 2200.0,
    delay_locked: bool = False,
    delays: tuple[float, ...] = (2300.0, 2302.0, 2298.0),
    context_signature: str = "ctx-a",
    enabled_airplay_count: int = 1,
    active_airplay_count: int | None = 1,
    airplay_timing_epoch: int = 1,
    sync_context_state: str = "suspect",
    sync_context_revision: int = 7,
    capture_backend: str = "tap",
    multi_path: bool = False,
    multi_path_delta_ms: float = 75.0,
) -> dict:
    rows = []
    for index, delay in enumerate(delays, start=1):
        rows.append(
            {
                "index": index,
                "verdict": "accepted",
                "delay_ms": delay,
                "current_delay_ms": current_delay_ms,
                "delay_locked": delay_locked,
                "context_signature": context_signature,
                "enabled_airplay_count": enabled_airplay_count,
                "active_airplay_count": active_airplay_count,
                "airplay_timing_epoch": airplay_timing_epoch,
                "sync_context_state": sync_context_state,
                "sync_context_revision": sync_context_revision,
                "capture_backend": capture_backend,
                "inconclusive_reason": None,
                "sample": {
                    "cycles": [
                        _cycle(
                            delay,
                            multi_path=multi_path,
                            multi_path_delta_ms=multi_path_delta_ms,
                        )
                    ]
                },
            }
        )
    delay_range = max(delays) - min(delays)
    return {
        "summary": {
            "verdict": verdict,
            "reason": None if verdict == "stable" else "not stable",
            "samples_total": len(rows),
            "samples_accepted": len(rows),
            "required_accepted": 2,
            "delay_median_ms": sorted(delays)[len(delays) // 2],
            "delay_range_ms": delay_range,
            "delay_end_to_start_ms": delays[-1] - delays[0],
            "trailing_inconclusive_samples": 0,
            "context_gate": None,
        },
        "rows": rows,
    }


class PassiveDelayDecisionTests(unittest.TestCase):
    def test_initializes_relative_baseline_without_applying(self):
        decision = pdd.decide(_payload())
        self.assertEqual(decision["verdict"], "initialize_baseline")
        self.assertFalse(decision["auto_apply_eligible"])
        self.assertEqual(decision["baseline_offset_ms"], 100.0)

    def test_recommends_small_relative_correction_from_baseline_offset(self):
        decision = pdd.decide(
            _payload(
                delays=(2318.0, 2320.0, 2316.0),
                sync_context_state="valid",
                sync_context_revision=8,
            ),
            baseline_offset_ms=100.0,
            deadband_ms=5.0,
        )
        self.assertEqual(decision["verdict"], "recommend")
        self.assertTrue(decision["auto_apply_eligible"])
        self.assertEqual(decision["raw_correction_ms"], 118.0 - 100.0)
        self.assertEqual(decision["recommended_delay_ms"], 2218)

    def test_holds_inside_deadband(self):
        decision = pdd.decide(
            _payload(delays=(2305.0, 2306.0, 2304.0)),
            baseline_offset_ms=100.0,
            deadband_ms=8.0,
        )
        self.assertEqual(decision["verdict"], "hold")
        self.assertEqual(decision["recommended_delay_ms"], 2200)

    def test_limits_large_but_allowed_step(self):
        decision = pdd.decide(
            _payload(
                delays=(2250.0, 2252.0, 2248.0),
                current_delay_ms=2100.0,
                sync_context_state="valid",
                sync_context_revision=8,
            ),
            baseline_offset_ms=100.0,
            deadband_ms=5.0,
            max_step_ms=20.0,
            max_correction_ms=80.0,
        )
        self.assertEqual(decision["verdict"], "recommend")
        self.assertFalse(decision["auto_apply_eligible"])
        self.assertTrue(decision["limited_by_step"])
        self.assertEqual(decision["limited_correction_ms"], 20.0)
        self.assertEqual(decision["recommended_delay_ms"], 2120)

    def test_rejects_correction_while_sync_context_is_suspect(self):
        decision = pdd.decide(
            _payload(delays=(2318.0, 2320.0, 2316.0)),
            baseline_offset_ms=100.0,
            deadband_ms=5.0,
        )
        self.assertEqual(decision["verdict"], "reject")
        self.assertFalse(decision["auto_apply_eligible"])
        self.assertIn("valid Local+AirPlay sync context", decision["reason"])

    def test_rejects_missing_active_airplay_count(self):
        with self.assertRaisesRegex(ValueError, "active AirPlay count"):
            pdd.decide(_payload(active_airplay_count=None))

    def test_rejects_inactive_airplay_evidence(self):
        with self.assertRaisesRegex(
            pdd.DecisionRejected,
            "every enabled AirPlay output",
        ):
            pdd.decide(
                _payload(
                    enabled_airplay_count=2,
                    active_airplay_count=1,
                )
            )

    def test_rejects_unstable_monitor(self):
        with self.assertRaisesRegex(ValueError, "not stable"):
            pdd.decide(_payload(verdict="unstable"), baseline_offset_ms=100.0)

    def test_coherent_multipath_initializes_baseline_without_correction(self):
        decision = pdd.decide(
            _payload(multi_path=True, multi_path_delta_ms=18.0),
            deadband_ms=5.0,
        )
        self.assertEqual(decision["verdict"], "initialize_baseline")
        self.assertFalse(decision["auto_apply_eligible"])
        self.assertEqual(
            decision["decision_basis"],
            "coherent_path_pair_unverified_baseline",
        )
        self.assertEqual(decision["baseline_path_pair_delta_ms"], 18.0)
        self.assertNotIn("recommended_delay_ms", decision)
        self.assertEqual(decision["features"]["path_pair_delta_ms"], 18.0)

    def test_coherent_multipath_large_first_delta_is_only_baseline(self):
        decision = pdd.decide(
            _payload(multi_path=True, multi_path_delta_ms=75.0),
            deadband_ms=5.0,
        )
        self.assertEqual(decision["verdict"], "initialize_baseline")
        self.assertFalse(decision["auto_apply_eligible"])
        self.assertNotIn("limited_by_step", decision)
        self.assertNotIn("recommended_delay_ms", decision)

    def test_finds_coherent_pair_beyond_strongest_two_candidates(self):
        payload = _payload(delays=(2300.0, 2301.0, 2299.0))
        for row in payload["rows"]:
            delay = float(row["delay_ms"])
            row["sample"]["cycles"] = [
                {
                    "index": 1,
                    "estimate": {
                        "path_candidates": [
                            {
                                "delay_ms": delay + 85.0,
                                "window_fraction": 1.0,
                                "mean_score": 0.98,
                            },
                            {
                                "delay_ms": delay,
                                "window_fraction": 0.93,
                                "mean_score": 0.74,
                            },
                            {
                                "delay_ms": delay + 18.0,
                                "window_fraction": 0.82,
                                "mean_score": 0.66,
                            },
                        ]
                    },
                    "strong_peaks": {
                        "count": 3,
                        "spread_ms": 85.0,
                        "delays_ms": [delay, delay + 18.0, delay + 85.0],
                    },
                }
            ]

        decision = pdd.decide(payload, deadband_ms=5.0)

        self.assertEqual(decision["verdict"], "initialize_baseline")
        self.assertEqual(decision["baseline_path_pair_delta_ms"], 18.0)
        self.assertEqual(decision["features"]["path_pair_delta_ms"], 18.0)
        self.assertEqual(
            decision["features"]["path_pair_explained_flagged_cycles"],
            3,
        )

    def test_rejects_multipath_when_no_candidate_maps_to_local_delay(self):
        with self.assertRaisesRegex(ValueError, "not coherently explained"):
            pdd.decide(
                _payload(
                    current_delay_ms=1200.0,
                    multi_path=True,
                    multi_path_delta_ms=18.0,
                ),
                deadband_ms=5.0,
            )

    def test_does_not_synthesize_path_pair_across_separate_cycles(self):
        payload = _payload(delays=(2200.0, 2201.0, 2199.0))
        for row in payload["rows"]:
            row["sample"]["cycles"] = [
                {
                    "index": 1,
                    "estimate": {
                        "path_candidates": [
                            {
                                "delay_ms": 2200.0,
                                "window_fraction": 1.0,
                                "mean_score": 0.9,
                            }
                        ]
                    },
                    "strong_peaks": {
                        "count": 1,
                        "spread_ms": 0.0,
                        "delays_ms": [2200.0],
                    },
                },
                {
                    "index": 2,
                    "estimate": {
                        "path_candidates": [
                            {
                                "delay_ms": 2218.0,
                                "window_fraction": 1.0,
                                "mean_score": 0.9,
                            }
                        ]
                    },
                    "strong_peaks": {
                        "count": 1,
                        "spread_ms": 0.0,
                        "delays_ms": [2218.0],
                    },
                },
            ]
        decision = pdd.decide(payload, deadband_ms=5.0)
        self.assertEqual(decision["verdict"], "initialize_baseline")
        self.assertNotIn("path_pair_delta_ms", decision["features"])

    def test_rejects_unexplained_multipath_even_with_some_coherent_pairs(self):
        payload = _payload(multi_path=True, multi_path_delta_ms=18.0)
        for row in payload["rows"]:
            row["sample"]["cycles"].append(
                {
                    "index": 2,
                    "estimate": {
                        "path_candidates": [
                            {
                                "delay_ms": 2600.0,
                                "window_fraction": 1.0,
                                "mean_score": 0.9,
                            },
                            {
                                "delay_ms": 2700.0,
                                "window_fraction": 0.9,
                                "mean_score": 0.8,
                            },
                        ]
                    },
                    "strong_peaks": {
                        "count": 2,
                        "spread_ms": 100.0,
                        "delays_ms": [2600.0, 2700.0],
                    },
                }
            )
        with self.assertRaisesRegex(ValueError, "not coherently explained"):
            pdd.decide(payload, deadband_ms=5.0)

    def test_can_allow_multipath_for_diagnostics(self):
        decision = pdd.decide(
            _payload(multi_path=True),
            baseline_offset_ms=100.0,
            allow_multipath=True,
        )
        self.assertEqual(decision["verdict"], "hold")

    def test_uses_explicit_baseline_path_pair_delta(self):
        decision = pdd.decide(
            _payload(
                multi_path=True,
                multi_path_delta_ms=18.0,
                sync_context_state="valid",
                sync_context_revision=8,
            ),
            baseline_offset_ms=100.0,
            baseline_path_pair_delta_ms=3.0,
            deadband_ms=5.0,
        )
        self.assertEqual(decision["verdict"], "recommend")
        self.assertEqual(decision["decision_basis"], "coherent_path_pair_relative")
        self.assertEqual(decision["raw_correction_ms"], 15.0)
        self.assertEqual(decision["recommended_delay_ms"], 2215)

    def test_rejects_current_path_pair_against_legacy_single_path_baseline(self):
        decision = pdd.decide(
            _payload(
                multi_path=True,
                multi_path_delta_ms=18.0,
                sync_context_state="valid",
                sync_context_revision=8,
            ),
            baseline_offset_ms=100.0,
            deadband_ms=5.0,
        )
        self.assertEqual(decision["verdict"], "reject")
        self.assertFalse(decision["auto_apply_eligible"])
        self.assertEqual(
            decision["decision_basis"],
            "coherent_path_pair_missing_baseline",
        )

    def test_coherent_multipath_relative_against_baseline_payload(self):
        decision = pdd.decide(
            _payload(
                multi_path=True,
                multi_path_delta_ms=18.0,
                sync_context_state="valid",
                sync_context_revision=8,
            ),
            baseline_payload=_payload(
                multi_path=True,
                multi_path_delta_ms=10.0,
                sync_context_state="valid",
                sync_context_revision=8,
            ),
            deadband_ms=5.0,
        )
        self.assertEqual(decision["verdict"], "recommend")
        self.assertEqual(decision["decision_basis"], "coherent_path_pair_relative")
        self.assertEqual(decision["raw_correction_ms"], 8.0)
        self.assertEqual(decision["recommended_delay_ms"], 2208)

    def test_allows_multiple_airplay_group_by_default(self):
        decision = pdd.decide(
            _payload(enabled_airplay_count=2, active_airplay_count=2),
            baseline_offset_ms=100.0,
        )
        self.assertEqual(decision["verdict"], "hold")
        self.assertEqual(decision["features"]["enabled_airplay_count"], 2)
        self.assertEqual(decision["features"]["active_airplay_count"], 2)

    def test_can_require_single_airplay_for_legacy_diagnostics(self):
        with self.assertRaisesRegex(ValueError, "exactly one enabled AirPlay"):
            pdd.decide(
                _payload(enabled_airplay_count=2, active_airplay_count=2),
                baseline_offset_ms=100.0,
                allow_multiple_airplay=False,
            )

    def test_rejects_too_many_airplay_receivers(self):
        with self.assertRaisesRegex(ValueError, "at most 8 enabled AirPlay"):
            pdd.decide(
                _payload(enabled_airplay_count=9, active_airplay_count=9),
                baseline_offset_ms=100.0,
            )

    def test_rejects_changed_current_delay(self):
        payload = _payload()
        payload["rows"][1]["current_delay_ms"] = 2210
        with self.assertRaisesRegex(ValueError, "changed current delay"):
            pdd.decide(payload, baseline_offset_ms=100.0)

    def test_rejects_locked_delay_state(self):
        with self.assertRaisesRegex(ValueError, "locked manual delay"):
            pdd.decide(_payload(delay_locked=True), baseline_offset_ms=100.0)

    def test_rejects_changed_delay_lock_state(self):
        payload = _payload()
        payload["rows"][1]["delay_locked"] = True
        with self.assertRaisesRegex(ValueError, "changed delay lock state"):
            pdd.decide(payload, baseline_offset_ms=100.0)

    def test_rejects_missing_delay_lock_state(self):
        payload = _payload()
        for row in payload["rows"]:
            row.pop("delay_locked")
        with self.assertRaisesRegex(ValueError, "missing delay lock state"):
            pdd.decide(payload, baseline_offset_ms=100.0)

    def test_rejects_invalid_baseline_report(self):
        with self.assertRaisesRegex(ValueError, "baseline_payload or baseline_offset"):
            pdd.decide(
                _payload(),
                baseline_payload=_payload(),
                baseline_offset_ms=100.0,
            )
        with self.assertRaisesRegex(ValueError, "finite number"):
            pdd.decide(_payload(), baseline_offset_ms=float("nan"))
        with self.assertRaisesRegex(ValueError, "not stable"):
            pdd.decide(
                _payload(),
                baseline_payload=_payload(verdict="inconclusive"),
            )

    def test_rejects_baseline_from_different_route_context(self):
        with self.assertRaisesRegex(ValueError, "baseline route context"):
            pdd.decide(
                _payload(context_signature="ctx-b"),
                baseline_payload=_payload(context_signature="ctx-a"),
            )
        with self.assertRaisesRegex(ValueError, "baseline capture backend"):
            pdd.decide(
                _payload(capture_backend="sck"),
                baseline_payload=_payload(capture_backend="tap"),
            )
        with self.assertRaisesRegex(ValueError, "baseline AirPlay timing epoch"):
            pdd.decide(
                _payload(airplay_timing_epoch=2),
                baseline_payload=_payload(airplay_timing_epoch=1),
            )

    def test_cli_reads_report_and_baseline_offset(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "report.json"
            report.write_text(json.dumps(
                _payload(
                    delays=(2318.0, 2320.0, 2316.0),
                    sync_context_state="valid",
                    sync_context_revision=8,
                )
            ))
            old_parse = pdd._parse_args
            try:
                pdd._parse_args = lambda: type(
                    "Args",
                    (),
                    {
                        "report": report,
                        "baseline_report": None,
                        "baseline_offset_ms": 100.0,
                        "min_accepted_samples": 2,
                        "max_delay_range_ms": 30.0,
                        "deadband_ms": 5.0,
                        "max_step_ms": 20.0,
                        "max_correction_ms": 80.0,
                        "delay_min_ms": 0.0,
                        "delay_max_ms": 5000.0,
                        "allow_multiple_airplay": False,
                        "single_airplay_only": False,
                        "allow_multipath": False,
                    },
                )()
                with mock.patch("sys.stdout"):
                    rc = pdd.main()
            finally:
                pdd._parse_args = old_parse
        self.assertEqual(rc, pdd.EXIT_OK)

    def test_cli_returns_not_applicable_for_unsafe_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "report.json"
            report.write_text(json.dumps(_payload(verdict="unstable")))
            old_parse = pdd._parse_args
            try:
                pdd._parse_args = lambda: type(
                    "Args",
                    (),
                    {
                        "report": report,
                        "baseline_report": None,
                        "baseline_offset_ms": 100.0,
                        "min_accepted_samples": 2,
                        "max_delay_range_ms": 30.0,
                        "deadband_ms": 5.0,
                        "max_step_ms": 20.0,
                        "max_correction_ms": 80.0,
                        "delay_min_ms": 0.0,
                        "delay_max_ms": 5000.0,
                        "allow_multiple_airplay": False,
                        "single_airplay_only": False,
                        "allow_multipath": False,
                    },
                )()
                with mock.patch("sys.stderr"):
                    rc = pdd.main()
            finally:
                pdd._parse_args = old_parse
        self.assertEqual(rc, pdd.EXIT_NOT_APPLICABLE)


if __name__ == "__main__":
    unittest.main()
