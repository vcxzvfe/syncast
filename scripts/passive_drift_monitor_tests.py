#!/usr/bin/env python3
from __future__ import annotations

import argparse
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import passive_drift_monitor as pdm


def _row(delay_ms, verdict="accepted", **overrides):
    row = {
        "verdict": verdict,
        "delay_ms": delay_ms,
    }
    row.update(overrides)
    return row


def _monitor_args(**overrides):
    values = dict(
        socket=Path("/tmp/fake-syncast.sock"),
        samples=1,
        interval_sec=0.0,
        cycles=3,
        duration_sec=4.0,
        max_delay_ms=3500,
        output_root=None,
        report_path=None,
        jsonl_path=None,
        preflight_only=False,
        max_monitor_drift_ms=30.0,
        min_sample_fraction=0.66,
        max_trailing_inconclusive_samples=0,
        max_accepted_gap_samples=0,
        min_final_accepted_run=2,
        min_ms=0.0,
        max_ms=None,
        mode="waveform",
        window_sec=2.0,
        hop_sec=1.0,
        min_rms=0.0005,
        min_score=0.04,
        min_prominence=1.02,
        min_peak_z=6.0,
        min_accepted_window_fraction=0.50,
        max_feature_delta_ms=25.0,
        peak_separation_ms=20.0,
        cluster_radius_ms=10.0,
        min_cluster_fraction=0.6,
        max_mad_ms=10.0,
        min_valid_reference_ratio=0.98,
        min_cycle_fraction=0.66,
        cycle_cluster_radius_ms=20.0,
        max_cycle_range_ms=20.0,
        max_cycle_mad_ms=15.0,
        max_estimate_slope_ms_per_min=None,
        strong_peak_relative_score=0.45,
        strong_peak_relative_count=0.5,
        max_strong_peak_spread_ms=60.0,
        allow_single_cycle_accept=False,
    )
    values.update(overrides)
    return argparse.Namespace(**values)


def _ready_status(**overrides):
    status = {
        "ok": True,
        "currentDelayMs": 2250,
        "contextSignature": "ctx-a",
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "airplayTimingEpoch": 1,
        "syncContextState": "suspect",
        "syncContextRevision": 7,
        "captureBackend": "tap",
        "passiveCaptureAvailable": True,
        "inProgress": False,
        "delayLocked": False,
        "syncContextState": "suspect",
        "syncContextRevision": 7,
        "captureTickCount": 12,
    }
    status.update(overrides)
    return status


def _capture_context(context="ctx-a", current_delay=2250, backend="tap"):
    return {
        "sampleRate": 48000,
        "referenceFrames": 100,
        "microphoneFrames": 100,
        "validReferenceFrames": 100,
        "maxDelayMs": 3500,
        "microphoneArmedAtNs": 1_000_000_000,
        "microphoneFirstSampleAtNs": 1_000_000_000,
        "microphoneStartPaddingFrames": 0,
        "microphoneWarmupFramesDropped": 128,
        "currentDelayMs": current_delay,
        "contextSignature": context,
        "delayLocked": False,
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "airplayTimingEpoch": 1,
        "syncContextState": "suspect",
        "syncContextReason": "route changed",
        "syncContextRevision": 7,
        "backend": backend,
        "contextStableDuringCapture": True,
        "endCurrentDelayMs": current_delay,
        "endContextSignature": context,
        "endDelayLocked": False,
        "endEnabledAirplayCount": 1,
        "endActiveAirplayCount": 1,
        "endAirplayTimingEpoch": 1,
        "endSyncContextState": "suspect",
        "endSyncContextReason": "route changed",
        "endSyncContextRevision": 7,
    }


def _estimate_args(**overrides):
    values = dict(
        min_valid_reference_ratio=0.98,
        min_cycle_fraction=0.66,
        cycle_cluster_radius_ms=20.0,
        max_cycle_range_ms=20.0,
        max_cycle_mad_ms=15.0,
        max_feature_delta_ms=25.0,
        max_estimate_slope_ms_per_min=None,
        max_strong_peak_spread_ms=60.0,
        allow_single_cycle_accept=False,
    )
    values.update(overrides)
    return argparse.Namespace(**values)


class PassiveDriftMonitorTests(unittest.TestCase):
    def test_stable_when_accepted_delay_range_is_small(self):
        result = pdm._summarize_rows(
            [_row(100.0), _row(104.0), _row(98.0)],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "stable")
        self.assertEqual(result["samples_accepted"], 3)
        self.assertEqual(result["delay_range_ms"], 6.0)

    def test_all_missing_context_metadata_keeps_legacy_reports_supported(self):
        result = pdm._summarize_rows(
            [_row(100.0), _row(104.0), _row(98.0)],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "stable")
        self.assertNotIn("context_gate", result)

    def test_stable_when_context_metadata_is_consistent(self):
        rows = [
            _row(
                100.0,
                context_signature="ctx-a",
                current_delay_ms=2250,
                enabled_airplay_count=1,
                active_airplay_count=1,
                capture_backend="tap",
                delay_locked=False,
            ),
            _row(
                104.0,
                context_signature="ctx-a",
                current_delay_ms=2250,
                enabled_airplay_count=1,
                active_airplay_count=1,
                capture_backend="tap",
                delay_locked=False,
            ),
            _row(
                98.0,
                context_signature="ctx-a",
                current_delay_ms=2250,
                enabled_airplay_count=1,
                active_airplay_count=1,
                capture_backend="tap",
                delay_locked=False,
            ),
        ]
        result = pdm._summarize_rows(
            rows,
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "stable")
        self.assertNotIn("context_gate", result)

    def test_unstable_when_delay_range_exceeds_threshold(self):
        result = pdm._summarize_rows(
            [_row(100.0), _row(104.0), _row(140.0)],
            min_ok_fraction=0.66,
            max_drift_ms=20.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "unstable")
        self.assertIn("passive delay range", result["reason"])

    def test_unstable_when_route_context_changes_even_if_delay_range_is_small(self):
        result = pdm._summarize_rows(
            [
                _row(100.0, context_signature="ctx-a"),
                _row(103.0, context_signature="ctx-b"),
                _row(101.0, context_signature="ctx-b"),
            ],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "unstable")
        self.assertIn("route context changed", result["reason"])
        self.assertEqual(
            result["context_gate"]["context_signatures"],
            ["ctx-a", "ctx-b"],
        )
        self.assertEqual(result["delay_range_ms"], 3.0)

    def test_unstable_when_applied_delay_changes_during_monitor(self):
        result = pdm._summarize_rows(
            [
                _row(100.0, current_delay_ms=2250),
                _row(103.0, current_delay_ms=2260),
                _row(101.0, current_delay_ms=2260),
            ],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "unstable")
        self.assertIn("applied delay changed", result["reason"])
        self.assertEqual(
            result["context_gate"]["current_delay_values_ms"],
            [2250, 2260],
        )

    def test_unstable_when_airplay_timing_epoch_changes_during_monitor(self):
        result = pdm._summarize_rows(
            [
                _row(100.0, airplay_timing_epoch=1),
                _row(103.0, airplay_timing_epoch=2),
                _row(101.0, airplay_timing_epoch=2),
            ],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "unstable")
        self.assertIn("AirPlay timing epoch changed", result["reason"])
        self.assertEqual(result["context_gate"]["field"], "airplay_timing_epoch")

    def test_unstable_when_active_airplay_count_changes_during_monitor(self):
        result = pdm._summarize_rows(
            [
                _row(100.0, active_airplay_count=2),
                _row(103.0, active_airplay_count=1),
                _row(101.0, active_airplay_count=1),
            ],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "unstable")
        self.assertIn("active AirPlay count changed", result["reason"])
        self.assertEqual(result["context_gate"]["field"], "active_airplay_count")
        self.assertEqual(result["context_gate"]["active_airplay_counts"], [2, 1])

    def test_inconclusive_when_active_airplay_count_metadata_is_partial(self):
        result = pdm._summarize_rows(
            [
                _row(100.0, active_airplay_count=1),
                _row(103.0),
                _row(101.0, active_airplay_count=1),
            ],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertIn("incomplete passive context metadata", result["reason"])
        self.assertEqual(result["context_gate"]["field"], "active_airplay_count")

    def test_inconclusive_when_context_metadata_is_partial(self):
        result = pdm._summarize_rows(
            [
                _row(100.0, context_signature="ctx-a"),
                _row(103.0),
                _row(101.0, context_signature="ctx-a"),
            ],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertIn("incomplete passive context metadata", result["reason"])
        self.assertEqual(result["context_gate"]["samples_with_value"], 2)

    def test_inconclusive_when_not_enough_samples_accept(self):
        result = pdm._summarize_rows(
            [_row(100.0), _row(None, "inconclusive"), _row(None, "inconclusive")],
            min_ok_fraction=0.66,
            max_drift_ms=20.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertEqual(result["required_accepted"], 2)

    def test_two_of_three_accepted_samples_can_be_stable(self):
        result = pdm._summarize_rows(
            [_row(100.0), _row(103.0), _row(None, "inconclusive")],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=1,
        )
        self.assertEqual(result["verdict"], "stable")
        self.assertEqual(result["samples_accepted"], 2)
        self.assertEqual(result["required_accepted"], 2)
        self.assertEqual(result["final_accepted_run"], 2)

    def test_inconclusive_when_accepted_samples_have_gap(self):
        result = pdm._summarize_rows(
            [
                _row(100.0),
                _row(None, "inconclusive"),
                _row(101.0),
                _row(102.0),
            ],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertIn("not contiguous enough", result["reason"])
        self.assertEqual(result["max_accepted_gap_samples"], 1)

    def test_inconclusive_when_recent_accepted_run_is_too_short(self):
        result = pdm._summarize_rows(
            [
                _row(100.0),
                _row(101.0),
                _row(None, "inconclusive"),
                _row(102.0),
            ],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
            max_accepted_gap_samples=1,
            min_final_accepted_run=2,
        )
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertIn("final accepted run", result["reason"])
        self.assertEqual(result["final_accepted_run"], 1)
        self.assertEqual(result["required_final_accepted_run"], 2)

    def test_trailing_inconclusive_samples_fail_closed_by_default(self):
        result = pdm._summarize_rows(
            [
                _row(100.0),
                _row(103.0),
                _row(101.0),
                _row(102.0),
                _row(None, "inconclusive"),
                _row(None, "inconclusive"),
            ],
            min_ok_fraction=0.66,
            max_drift_ms=10.0,
            max_trailing_inconclusive_samples=0,
        )
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertIn("trailing inconclusive", result["reason"])

    def test_monitor_validation_reports_monitor_args_before_socket(self):
        args = argparse.Namespace(
            samples=0,
            interval_sec=0.0,
            max_monitor_drift_ms=30.0,
            min_sample_fraction=0.66,
            max_trailing_inconclusive_samples=0,
            max_accepted_gap_samples=0,
            min_final_accepted_run=2,
            socket=Path("/tmp/definitely-not-a-syncast-socket"),
            cycles=3,
            duration_sec=4.0,
            max_delay_ms=3500,
            min_ms=0.0,
            max_ms=None,
            min_peak_z=6.0,
            min_accepted_window_fraction=0.50,
            min_cluster_fraction=0.6,
            min_valid_reference_ratio=0.98,
            min_cycle_fraction=0.66,
            cycle_cluster_radius_ms=20.0,
            max_cycle_range_ms=20.0,
            max_cycle_mad_ms=15.0,
            max_strong_peak_spread_ms=60.0,
            strong_peak_relative_score=0.45,
            strong_peak_relative_count=0.5,
        )
        with self.assertRaisesRegex(ValueError, "--samples must be >= 1"):
            pdm._validate_args(args)

    def test_estimate_args_propagates_feature_and_slope_gates(self):
        args = _monitor_args(
            max_feature_delta_ms=12.5,
            max_estimate_slope_ms_per_min=33.0,
        )
        estimate_args = pdm._estimate_args(args)
        self.assertEqual(estimate_args.max_feature_delta_ms, 12.5)
        self.assertEqual(estimate_args.max_estimate_slope_ms_per_min, 33.0)

    def test_estimate_args_defaults_new_gates_for_legacy_namespace(self):
        args = _monitor_args()
        delattr(args, "max_feature_delta_ms")
        delattr(args, "max_estimate_slope_ms_per_min")
        estimate_args = pdm._estimate_args(args)
        self.assertEqual(estimate_args.max_feature_delta_ms, 25.0)
        self.assertIsNone(estimate_args.max_estimate_slope_ms_per_min)

    def test_exit_code_mapping(self):
        self.assertEqual(pdm._exit_code_for_verdict("stable"), pdm.EXIT_OK)
        self.assertEqual(pdm._exit_code_for_verdict("unstable"), pdm.EXIT_UNSTABLE)
        self.assertEqual(
            pdm._exit_code_for_verdict("capture_failed"),
            pdm.EXIT_CAPTURE_FAILED,
        )
        self.assertEqual(
            pdm._exit_code_for_verdict("inconclusive"),
            pdm.EXIT_INCONCLUSIVE,
        )

    def test_report_write_and_jsonl_append(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "nested" / "report.json"
            jsonl = Path(tmp) / "nested" / "samples.jsonl"
            pdm._write_json(report, {"summary": {"verdict": "stable"}, "rows": []})
            pdm._append_jsonl(jsonl, {"index": 1, "verdict": "accepted"})
            pdm._append_jsonl(jsonl, {"index": 2, "verdict": "inconclusive"})

            self.assertIn('"verdict": "stable"', report.read_text())
            lines = jsonl.read_text().strip().splitlines()
            self.assertEqual(len(lines), 2)
            self.assertIn('"index": 1', lines[0])

    def test_main_writes_failure_report_with_partial_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "report.json"
            jsonl = Path(tmp) / "samples.jsonl"
            args = _monitor_args(
                samples=2,
                report_path=report,
                jsonl_path=jsonl,
            )
            first_sample = {
                "verdict": "accepted",
                "summary": {
                    "delay_ms": 101.0,
                    "delay_mad_ms": 0.5,
                    "delay_range_ms": 1.0,
                    "cycles_accepted": 3,
                    "cycles_clustered": 3,
                    "inconclusive_reason": None,
                },
                "cycles": [],
            }
            with mock.patch.object(pdm, "_parse_args", return_value=args), \
                 mock.patch.object(pdm, "_validate_args"), \
                 mock.patch.object(pdm.pce, "_check_socket_ready"), \
                 mock.patch.object(
                     pdm.pce,
                     "_passive_capture_preflight",
                     return_value=_ready_status(),
                 ), \
                 mock.patch.object(
                     pdm,
                     "_capture_sample",
                     side_effect=[first_sample, RuntimeError("capture dropped")],
                 ), \
                 mock.patch.object(sys, "stdout", io.StringIO()), \
                 mock.patch.object(sys, "stderr", io.StringIO()):
                rc = pdm.main()

            self.assertEqual(rc, pdm.EXIT_CAPTURE_FAILED)
            payload = json.loads(report.read_text())
            self.assertEqual(payload["summary"]["verdict"], "capture_failed")
            self.assertEqual(payload["summary"]["samples_total"], 1)
            self.assertIn("capture dropped", payload["summary"]["reason"])
            self.assertEqual(len(payload["rows"]), 1)
            self.assertEqual(len(jsonl.read_text().strip().splitlines()), 1)

    def test_main_writes_failure_report_on_keyboard_interrupt(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "report.json"
            args = _monitor_args(samples=2, report_path=report)
            with mock.patch.object(pdm, "_parse_args", return_value=args), \
                 mock.patch.object(pdm, "_validate_args"), \
                 mock.patch.object(pdm.pce, "_check_socket_ready"), \
                 mock.patch.object(
                     pdm.pce,
                     "_passive_capture_preflight",
                     return_value=_ready_status(),
                 ), \
                 mock.patch.object(
                     pdm,
                     "_capture_sample",
                     side_effect=KeyboardInterrupt(),
                 ), \
                 mock.patch.object(sys, "stdout", io.StringIO()), \
                 mock.patch.object(sys, "stderr", io.StringIO()):
                rc = pdm.main()

            self.assertEqual(rc, pdm.EXIT_CAPTURE_FAILED)
            payload = json.loads(report.read_text())
            self.assertEqual(payload["summary"]["verdict"], "capture_failed")
            self.assertIn("KeyboardInterrupt", payload["summary"]["reason"])

    def test_main_reports_failure_report_write_error_on_stderr(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "report.json"
            args = _monitor_args(report_path=report)
            stderr = io.StringIO()
            with mock.patch.object(pdm, "_parse_args", return_value=args), \
                 mock.patch.object(pdm, "_validate_args"), \
                 mock.patch.object(
                     pdm.pce,
                     "_check_socket_ready",
                     side_effect=RuntimeError("socket blocked"),
                 ), \
                 mock.patch.object(
                     pdm,
                     "_write_json",
                     side_effect=OSError("disk full"),
                 ), \
                 mock.patch.object(sys, "stdout", io.StringIO()), \
                 mock.patch.object(sys, "stderr", stderr):
                rc = pdm.main()

            self.assertEqual(rc, pdm.EXIT_CAPTURE_FAILED)
            payload = json.loads(stderr.getvalue())
            self.assertEqual(payload["verdict"], "capture_failed")
            self.assertIn("socket blocked", payload["error"])
            self.assertIn("disk full", payload["report_write_error"])

    def test_preflight_only_pings_socket_without_capture(self):
        args = _monitor_args(preflight_only=True)
        stdout = io.StringIO()
        status = {
            "ok": True,
            "currentDelayMs": 2250,
            "contextSignature": "ctx-a",
            "enabledAirplayCount": 1,
            "captureBackend": "tap",
            "passiveCaptureAvailable": True,
            "inProgress": False,
            "activeAirplayCount": 1,
            "airplayTimingEpoch": 1,
            "syncContextState": "suspect",
            "syncContextRevision": 7,
            "delayLocked": False,
            "captureTickCount": 12,
        }
        with mock.patch.object(pdm, "_parse_args", return_value=args), \
             mock.patch.object(pdm, "_validate_args") as validate_args, \
             mock.patch.object(pdm.pce, "_check_socket_ready") as check_socket, \
             mock.patch.object(
                 pdm.pce,
                 "_passive_capture_preflight",
                 return_value=status,
             ) as passive_capture_preflight, \
             mock.patch.object(pdm, "_capture_sample") as capture_sample, \
             mock.patch.object(sys, "stdout", stdout), \
             mock.patch.object(sys, "stderr", io.StringIO()):
            rc = pdm.main()

        self.assertEqual(rc, pdm.EXIT_OK)
        validate_args.assert_called_once_with(args)
        check_socket.assert_called_once_with(args.socket)
        passive_capture_preflight.assert_called_once_with(args.socket)
        capture_sample.assert_not_called()
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["verdict"], "preflight_ok")
        self.assertFalse(payload["opens_microphone"])
        self.assertFalse(payload["emits_audio"])
        self.assertFalse(payload["applies_delay"])
        self.assertEqual(payload["status"], status)
        self.assertEqual(payload["status"]["captureBackend"], "tap")

    def test_preflight_only_writes_report_without_jsonl(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "preflight.json"
            jsonl = Path(tmp) / "preflight.jsonl"
            args = _monitor_args(
                preflight_only=True,
                report_path=report,
                jsonl_path=jsonl,
            )
            with mock.patch.object(pdm, "_parse_args", return_value=args), \
                 mock.patch.object(pdm, "_validate_args"), \
                 mock.patch.object(pdm.pce, "_check_socket_ready"), \
                 mock.patch.object(
                     pdm.pce,
                     "_passive_capture_preflight",
                     return_value=_ready_status(),
                 ), \
                 mock.patch.object(sys, "stdout", io.StringIO()), \
                 mock.patch.object(sys, "stderr", io.StringIO()):
                rc = pdm.main()

            self.assertEqual(rc, pdm.EXIT_OK)
            payload = json.loads(report.read_text())
            self.assertEqual(payload["verdict"], "preflight_ok")
            self.assertFalse(jsonl.exists())

    def test_preflight_failure_never_enters_capture_loop(self):
        args = _monitor_args(preflight_only=False)
        stderr = io.StringIO()
        with mock.patch.object(pdm, "_parse_args", return_value=args), \
             mock.patch.object(pdm, "_validate_args"), \
             mock.patch.object(pdm.pce, "_check_socket_ready"), \
             mock.patch.object(
                 pdm.pce,
                 "_passive_capture_preflight",
                 side_effect=RuntimeError("enabled AirPlay output missing"),
             ), \
             mock.patch.object(pdm, "_capture_sample") as capture_sample, \
             mock.patch.object(sys, "stdout", io.StringIO()), \
             mock.patch.object(sys, "stderr", stderr):
            rc = pdm.main()

        self.assertEqual(rc, pdm.EXIT_CAPTURE_FAILED)
        capture_sample.assert_not_called()
        payload = json.loads(stderr.getvalue())
        self.assertEqual(payload["verdict"], "capture_failed")
        self.assertIn("enabled AirPlay", payload["error"])

    def test_zero_capture_ticks_preflight_never_enters_capture_loop(self):
        args = _monitor_args(preflight_only=False)
        stderr = io.StringIO()
        with mock.patch.object(pdm, "_parse_args", return_value=args), \
             mock.patch.object(pdm, "_validate_args"), \
             mock.patch.object(pdm.pce, "_check_socket_ready"), \
             mock.patch.object(
                 pdm.pce,
                 "_passive_capture_preflight",
                 side_effect=RuntimeError(
                     "passive capture reference has not received system-audio frames: captureTickCount=0"
                 ),
             ), \
             mock.patch.object(pdm, "_capture_sample") as capture_sample, \
             mock.patch.object(sys, "stdout", io.StringIO()), \
             mock.patch.object(sys, "stderr", stderr):
            rc = pdm.main()

        self.assertEqual(rc, pdm.EXIT_CAPTURE_FAILED)
        capture_sample.assert_not_called()
        payload = json.loads(stderr.getvalue())
        self.assertEqual(payload["verdict"], "capture_failed")
        self.assertIn("system-audio frames", payload["error"])

    def test_capture_sample_rechecks_status_before_later_cycles(self):
        captures = [
            {
                "referenceFrames": 100,
                "validReferenceFrames": 100,
                "maxDelayMs": 3500,
            },
        ]
        estimates = [
            {"delay_ms": 100.0, "mean_score": 0.5, "inconclusive_reason": None, "aggregate_peaks": []},
        ]
        with mock.patch.object(
                pdm.pce,
                "_passive_capture_preflight",
                side_effect=[
                    _ready_status(contextSignature="ctx-cycle-1"),
                    RuntimeError("passive capture is already in progress"),
                ],
             ), \
             mock.patch.object(pdm.pce, "_capture_once", side_effect=captures) as capture_once, \
             mock.patch.object(pdm.pce, "_estimate_capture", side_effect=estimates):
            with self.assertRaisesRegex(RuntimeError, "already in progress"):
                pdm._capture_sample(
                    sample_index=0,
                    args=_monitor_args(cycles=2),
                    estimate_args=_estimate_args(),
                )

        self.assertEqual(capture_once.call_count, 1)

    def test_capture_sample_propagates_inconclusive_cycles(self):
        captures = [
            _capture_context(context="mode=wholeHome|enabled=a"),
            _capture_context(context="mode=wholeHome|enabled=a"),
            _capture_context(context="mode=wholeHome|enabled=a"),
        ]
        estimates = [
            {"delay_ms": 100.0, "mean_score": 0.5, "inconclusive_reason": None, "aggregate_peaks": []},
            {"delay_ms": None, "mean_score": 0.0, "inconclusive_reason": "no accepted windows", "aggregate_peaks": []},
            {"delay_ms": 102.0, "mean_score": 0.5, "inconclusive_reason": None, "aggregate_peaks": []},
        ]
        with mock.patch.object(pdm.pce, "_capture_once", side_effect=captures), \
             mock.patch.object(pdm.pce, "_estimate_capture", side_effect=estimates), \
             mock.patch.object(
                 pdm.pce,
                 "_passive_capture_preflight",
                 side_effect=[
                     _ready_status(contextSignature="mode=wholeHome|enabled=a"),
                     _ready_status(contextSignature="mode=wholeHome|enabled=a"),
                     _ready_status(contextSignature="mode=wholeHome|enabled=a"),
                 ],
             ) as passive_capture_preflight:
            result = pdm._capture_sample(
                sample_index=0,
                args=_monitor_args(),
                estimate_args=_estimate_args(),
            )
        self.assertEqual(result["verdict"], "accepted")
        self.assertEqual(result["summary"]["cycles_accepted"], 2)
        self.assertEqual(result["summary"]["cycles_clustered"], 2)
        self.assertEqual(len(result["cycles"]), 3)
        self.assertEqual(passive_capture_preflight.call_count, 3)
        self.assertEqual(
            result["cycles"][0]["preflight"]["contextSignature"],
            "mode=wholeHome|enabled=a",
        )
        self.assertEqual(
            pdm._sample_context(result),
            {
                "current_delay_ms": 2250,
                "context_signature": "mode=wholeHome|enabled=a",
                "delay_locked": False,
                "enabled_airplay_count": 1,
                "active_airplay_count": 1,
                "airplay_timing_epoch": 1,
                "sync_context_state": "suspect",
                "sync_context_reason": "route changed",
                "sync_context_revision": 7,
                "capture_backend": "tap",
            },
        )


if __name__ == "__main__":
    unittest.main()
