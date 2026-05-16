#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

import passive_drift_summary as pds


def _payload(verdict="stable"):
    return {
        "summary": {
            "verdict": verdict,
            "reason": None if verdict == "stable" else "problem",
            "delay_range_ms": 4.0,
            "delay_end_to_start_ms": 2.0,
            "trailing_inconclusive_samples": 0,
            "context_gate": None,
        },
        "rows": [
            {
                "index": 1,
                "verdict": "accepted",
                "delay_ms": 100.0,
                "current_delay_ms": 2250,
                "context_signature": "ctx-a",
                "enabled_airplay_count": 1,
                "inconclusive_reason": None,
                "sample": {
                    "cycles": [
                        {
                            "index": 1,
                            "estimate": {
                                "path_candidates": [
                                    {"delay_ms": 100.0, "window_fraction": 1.0, "mean_score": 0.8}
                                ]
                            },
                            "strong_peaks": {
                                "count": 1,
                                "spread_ms": 0,
                                "delays_ms": [100.0],
                            },
                        }
                    ]
                },
            },
            {
                "index": 2,
                "verdict": "accepted",
                "delay_ms": 104.0,
                "current_delay_ms": 2250,
                "context_signature": "ctx-a",
                "enabled_airplay_count": 1,
                "inconclusive_reason": None,
                "sample": {
                    "cycles": [
                        {
                            "index": 1,
                            "estimate": {
                                "path_candidates": [
                                    {"delay_ms": 104.0, "window_fraction": 1.0, "mean_score": 0.8},
                                    {"delay_ms": 174.0, "window_fraction": 0.8, "mean_score": 0.5},
                                ]
                            },
                            "strong_peaks": {
                                "count": 2,
                                "spread_ms": 70.0,
                                "delays_ms": [104.0, 174.0],
                            },
                        }
                    ]
                },
            },
            {
                "index": 3,
                "verdict": "inconclusive",
                "delay_ms": None,
                "current_delay_ms": 2260,
                "context_signature": "ctx-b",
                "enabled_airplay_count": 2,
                "inconclusive_reason": "no accepted windows",
                "sample": {"cycles": []},
            },
        ],
    }


class PassiveDriftSummaryTests(unittest.TestCase):
    def test_summarize_payload_counts_verdicts_and_delay_range(self):
        summary = pds._summarize_payload(_payload())
        self.assertEqual(summary["monitor_verdict"], "stable")
        self.assertEqual(summary["source_format"], "json")
        self.assertFalse(summary["jsonl_recomputed"])
        self.assertEqual(summary["samples_total"], 3)
        self.assertEqual(summary["sample_verdict_counts"], {"accepted": 2, "inconclusive": 1})
        self.assertEqual(summary["accepted_delay_range_ms"], 4.0)
        self.assertEqual(summary["current_delay_values_ms"], [2250, 2260])
        self.assertEqual(summary["context_signature_count"], 2)
        self.assertEqual(summary["enabled_airplay_counts"], {"1": 2, "2": 1})
        self.assertIsNone(summary["context_gate"])
        self.assertEqual(summary["multi_path_candidate_flag_count"], 1)
        self.assertEqual(summary["top_inconclusive_reasons"][0]["reason"], "no accepted windows")

    def test_summarize_payload_preserves_context_gate(self):
        payload = _payload("unstable")
        gate = {
            "field": "context_signature",
            "context_signatures": ["ctx-a", "ctx-b"],
            "samples_with_value": 2,
            "samples_accepted": 2,
        }
        payload["summary"]["context_gate"] = gate
        summary = pds._summarize_payload(payload)
        self.assertEqual(summary["context_gate"], gate)

    def test_load_jsonl_rows_recomputes_monitor_summary(self):
        rows = [
            {"index": 1, "verdict": "accepted", "delay_ms": 100.0},
            {"index": 2, "verdict": "accepted", "delay_ms": 104.0},
            {"index": 3, "verdict": "accepted", "delay_ms": 101.0},
        ]
        raw = "\n".join(json.dumps(row) for row in rows)
        payload = pds._payload_from_jsonl_rows(
            pds._load_jsonl_rows(raw),
            min_sample_fraction=0.66,
            max_monitor_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        summary = pds._summarize_payload(payload)
        self.assertEqual(summary["monitor_verdict"], "stable")
        self.assertEqual(summary["source_format"], "jsonl")
        self.assertTrue(summary["jsonl_recomputed"])
        self.assertEqual(summary["monitor_delay_range_ms"], 4.0)

    def test_jsonl_recompute_preserves_context_gate(self):
        rows = [
            {"index": 1, "verdict": "accepted", "delay_ms": 100.0, "context_signature": "ctx-a"},
            {"index": 2, "verdict": "accepted", "delay_ms": 103.0, "context_signature": "ctx-b"},
            {"index": 3, "verdict": "accepted", "delay_ms": 101.0, "context_signature": "ctx-b"},
        ]
        payload = pds._payload_from_jsonl_rows(
            rows,
            min_sample_fraction=0.66,
            max_monitor_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        summary = pds._summarize_payload(payload)
        self.assertEqual(summary["monitor_verdict"], "unstable")
        self.assertEqual(summary["context_gate"]["field"], "context_signature")
        self.assertEqual(summary["monitor_delay_range_ms"], 3.0)

    def test_load_payload_auto_detects_jsonl_suffix(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "samples.jsonl"
            path.write_text(
                "\n".join(
                    [
                        json.dumps({"index": 1, "verdict": "accepted", "delay_ms": 100.0}),
                        json.dumps({"index": 2, "verdict": "accepted", "delay_ms": 101.0}),
                    ]
                )
            )
            payload = pds._load_payload(
                path,
                min_sample_fraction=1.0,
                max_monitor_drift_ms=5.0,
                max_trailing_inconclusive_samples=0,
            )
        self.assertEqual(payload["summary"]["verdict"], "stable")
        self.assertEqual(payload["summary"]["source_format"], "jsonl")

    def test_rejects_empty_jsonl(self):
        with self.assertRaisesRegex(ValueError, "no sample rows"):
            pds._load_jsonl_rows("\n\n")

    def test_rejects_malformed_jsonl_line(self):
        with self.assertRaisesRegex(ValueError, "invalid JSONL line 2"):
            pds._load_jsonl_rows('{"index": 1}\n{bad json}\n')

    def test_summarize_payload_reports_strong_peak_flags(self):
        summary = pds._summarize_payload(_payload())
        self.assertEqual(summary["strong_peak_flag_count"], 1)
        flag = summary["strong_peak_flags"][0]
        self.assertEqual(flag["sample"], 2)
        self.assertEqual(flag["cycle"], 1)
        self.assertEqual(flag["spread_ms"], 70.0)

    def test_summarize_payload_reports_multi_path_candidates(self):
        summary = pds._summarize_payload(_payload())
        flag = summary["multi_path_candidate_flags"][0]
        self.assertEqual(flag["sample"], 2)
        self.assertEqual(len(flag["paths"]), 2)
        self.assertEqual(flag["paths"][1]["delay_ms"], 174.0)
        self.assertIsNone(flag["candidate_windows"])

    def test_format_text_includes_core_fields(self):
        text = pds._format_text(pds._summarize_payload(_payload("unstable")))
        self.assertIn("verdict: unstable", text)
        self.assertIn("source : json recomputed=False", text)
        self.assertIn("context gate:", text)
        self.assertIn("strong peak flags: 1", text)
        self.assertIn("multi-path candidate flags: 1", text)
        self.assertIn("no accepted windows", text)

    def test_rejects_malformed_payload(self):
        with self.assertRaisesRegex(ValueError, "summary"):
            pds._summarize_payload({"summary": {}, "rows": {}})


if __name__ == "__main__":
    unittest.main()
