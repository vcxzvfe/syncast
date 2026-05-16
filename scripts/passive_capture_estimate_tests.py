#!/usr/bin/env python3
from __future__ import annotations

import argparse
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import passive_capture_estimate as pce


def _args(**overrides):
    values = dict(
        min_valid_reference_ratio=0.98,
        min_cycle_fraction=0.66,
        cycle_cluster_radius_ms=20.0,
        max_cycle_range_ms=20.0,
        max_cycle_mad_ms=15.0,
        max_estimate_slope_ms_per_min=None,
        max_strong_peak_spread_ms=60.0,
        allow_single_cycle_accept=False,
    )
    values.update(overrides)
    return argparse.Namespace(**values)


def _cycle(
    delay_ms,
    *,
    valid=100,
    reference=100,
    reason=None,
    score=0.5,
    context="ctx-a",
    current_delay=2200,
    backend="tap",
    enabled_airplay_count=1,
    active_airplay_count=1,
    airplay_timing_epoch=1,
    sync_context_state="suspect",
    sync_context_revision=4,
    delay_locked=False,
    slope_ms_per_min=0.0,
    include_context=True,
):
    capture = {
        "validReferenceFrames": valid,
        "referenceFrames": reference,
    }
    preflight = None
    if include_context:
        preflight = {
            "contextSignature": context,
            "currentDelayMs": current_delay,
            "enabledAirplayCount": enabled_airplay_count,
            "activeAirplayCount": active_airplay_count,
            "airplayTimingEpoch": airplay_timing_epoch,
            "syncContextState": sync_context_state,
            "syncContextRevision": sync_context_revision,
            "captureBackend": backend,
            "delayLocked": delay_locked,
        }
        capture.update(
            {
                "sampleRate": 48000,
                "microphoneFrames": 100,
                "microphoneArmedAtNs": 1_000_000_000,
                "microphoneFirstSampleAtNs": 1_000_000_000,
                "microphoneStartPaddingFrames": 0,
                "microphoneWarmupFramesDropped": 128,
                "contextSignature": context,
                "currentDelayMs": current_delay,
                "enabledAirplayCount": enabled_airplay_count,
                "activeAirplayCount": active_airplay_count,
                "airplayTimingEpoch": airplay_timing_epoch,
                "syncContextState": sync_context_state,
                "syncContextReason": "route changed",
                "syncContextRevision": sync_context_revision,
                "backend": backend,
                "delayLocked": delay_locked,
                "contextStableDuringCapture": True,
                "endContextSignature": context,
                "endCurrentDelayMs": current_delay,
                "endEnabledAirplayCount": enabled_airplay_count,
                "endActiveAirplayCount": active_airplay_count,
                "endAirplayTimingEpoch": airplay_timing_epoch,
                "endSyncContextState": sync_context_state,
                "endSyncContextReason": "route changed",
                "endSyncContextRevision": sync_context_revision,
                "endDelayLocked": delay_locked,
            }
        )
    cycle = {
        "capture": capture,
        "estimate": {
            "delay_ms": delay_ms,
            "delay_mad_ms": 0.0,
            "mean_score": score,
            "slope_ms_per_min": slope_ms_per_min,
            "inconclusive_reason": reason,
            "aggregate_peaks": [],
        },
    }
    if preflight is not None:
        cycle["preflight"] = preflight
    return cycle


def _capture_context(context="ctx-a", current_delay=2200, backend="tap"):
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
        "contextSignature": context,
        "currentDelayMs": current_delay,
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "airplayTimingEpoch": 1,
        "syncContextState": "suspect",
        "syncContextReason": "route changed",
        "syncContextRevision": 4,
        "backend": backend,
        "delayLocked": False,
        "contextStableDuringCapture": True,
        "endContextSignature": context,
        "endCurrentDelayMs": current_delay,
        "endEnabledAirplayCount": 1,
        "endActiveAirplayCount": 1,
        "endAirplayTimingEpoch": 1,
        "endSyncContextState": "suspect",
        "endSyncContextReason": "route changed",
        "endSyncContextRevision": 4,
        "endDelayLocked": False,
    }


def _cycle_with_context(delay_ms, *, context="ctx-a", current_delay=2200, backend="tap"):
    return _cycle(
        delay_ms,
        context=context,
        current_delay=current_delay,
        backend=backend,
        delay_locked=True,
    )


def _ready_status(**overrides):
    status = {
        "ok": True,
        "passiveCaptureAvailable": True,
        "inProgress": False,
        "captureBackend": "tap",
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "airplayTimingEpoch": 1,
        "syncContextState": "suspect",
        "syncContextReason": "route changed",
        "syncContextRevision": 4,
        "currentDelayMs": 2200,
        "delayLocked": False,
        "contextSignature": "mode=wholeHome|enabled=local,airplay",
    }
    status.update(overrides)
    return status


def _main_args(**overrides):
    values = dict(
        socket=Path("/tmp/fake-syncast.sock"),
        duration_sec=4.0,
        max_delay_ms=3500,
        output_root=None,
        report_path=None,
        cycles=2,
        preflight_only=False,
        allow_single_cycle_accept=False,
        interval_sec=0.0,
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
    )
    values.update(overrides)
    return argparse.Namespace(**values)


class PassiveCaptureEstimateTests(unittest.TestCase):
    def test_consensus_accepts_tight_cluster(self):
        result = pce._summarize_cycles(
            [_cycle(101.0), _cycle(103.0), _cycle(100.0)],
            _args(),
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["cycles_clustered"], 3)
        self.assertEqual(result["delay_ms"], 101.0)
        self.assertEqual(result["delay_mad_ms"], 1.0)
        self.assertEqual(result["estimate_slope_ms_per_min"], 0.0)

    def test_default_consensus_accepts_two_of_three_cycles(self):
        result = pce._summarize_cycles(
            [_cycle(101.0), _cycle(102.0), _cycle(None, reason="no signal")],
            _args(),
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["cycles_accepted"], 2)
        self.assertEqual(result["cycles_clustered"], 2)

    def test_consensus_rejects_bimodal_cycles(self):
        result = pce._summarize_cycles(
            [_cycle(100.0), _cycle(102.0), _cycle(500.0)],
            _args(min_cycle_fraction=1.0),
        )
        self.assertFalse(result["ok"])
        self.assertIn("no cross-cycle delay consensus", result["inconclusive_reason"])

    def test_single_cycle_is_diagnostic_only_by_default(self):
        result = pce._summarize_cycles([_cycle(100.0)], _args())
        self.assertFalse(result["ok"])
        self.assertIn("single-cycle passive estimates", result["inconclusive_reason"])

    def test_consensus_rejects_wide_seed_cluster(self):
        result = pce._summarize_cycles(
            [_cycle(100.0), _cycle(115.0), _cycle(130.0)],
            _args(max_cycle_range_ms=20.0),
        )
        self.assertFalse(result["ok"])
        self.assertIn("delay range too wide", result["inconclusive_reason"])

    def test_consensus_rejects_ambiguous_strong_peaks(self):
        ambiguous = _cycle(100.0)
        ambiguous["strong_peaks"] = {
            "count": 2,
            "spread_ms": 90.0,
            "delays_ms": [100.0, 190.0],
        }
        stable = _cycle(101.0)
        stable["strong_peaks"] = {
            "count": 1,
            "spread_ms": 0.0,
            "delays_ms": [101.0],
        }
        result = pce._summarize_cycles(
            [ambiguous, stable, _cycle(102.0)],
            _args(max_strong_peak_spread_ms=60.0),
        )
        self.assertFalse(result["ok"])
        self.assertIn("ambiguous strong aggregate peaks", result["inconclusive_reason"])

    def test_consensus_rejects_multi_peak_without_spread(self):
        ambiguous = _cycle(100.0)
        ambiguous["strong_peaks"] = {
            "count": 2,
            "delays_ms": [100.0, 160.0],
        }
        result = pce._summarize_cycles(
            [ambiguous, _cycle(101.0), _cycle(102.0)],
            _args(max_strong_peak_spread_ms=60.0),
        )
        self.assertFalse(result["ok"])
        self.assertIn("missing or invalid spread_ms", result["inconclusive_reason"])

    def test_consensus_rejects_multi_peak_with_malformed_spread(self):
        ambiguous = _cycle(100.0)
        ambiguous["strong_peaks"] = {
            "count": 2,
            "spread_ms": "not-a-number",
            "delays_ms": [100.0, 160.0],
        }
        result = pce._summarize_cycles(
            [ambiguous, _cycle(101.0), _cycle(102.0)],
            _args(max_strong_peak_spread_ms=60.0),
        )
        self.assertFalse(result["ok"])
        self.assertIn("missing or invalid spread_ms", result["inconclusive_reason"])

    def test_rejects_incomplete_reference(self):
        result = pce._summarize_cycles(
            [_cycle(100.0), _cycle(101.0, valid=70), _cycle(102.0)],
            _args(min_cycle_fraction=1.0),
        )
        self.assertFalse(result["ok"])
        self.assertIn("cycles accepted", result["inconclusive_reason"])

    def test_rejects_excessive_within_capture_drift_slope(self):
        result = pce._summarize_cycles(
            [
                _cycle(100.0, slope_ms_per_min=0.0),
                _cycle(101.0, slope_ms_per_min=80.0),
                _cycle(102.0, slope_ms_per_min=0.0),
            ],
            _args(min_cycle_fraction=1.0, max_estimate_slope_ms_per_min=30.0),
        )
        self.assertFalse(result["ok"])
        self.assertIn("estimate drift slope", result["cycle_rejects"][0]["reason"])

    def test_rejects_cycle_level_context_change(self):
        result = pce._summarize_cycles(
            [
                _cycle_with_context(100.0, context="ctx-a"),
                _cycle_with_context(101.0, context="ctx-b"),
                _cycle_with_context(102.0, context="ctx-a"),
            ],
            _args(),
        )
        self.assertFalse(result["ok"])
        self.assertIn("route context changed", result["inconclusive_reason"])
        self.assertEqual(result["context_gate"]["field"], "contextSignature")

    def test_rejects_capture_that_changed_context_mid_recording(self):
        changed = _cycle_with_context(100.0, context="ctx-a")
        changed["capture"]["endContextSignature"] = "ctx-b"
        result = pce._summarize_cycles(
            [
                changed,
                _cycle_with_context(101.0, context="ctx-a"),
                _cycle_with_context(102.0, context="ctx-a"),
            ],
            _args(),
        )
        self.assertFalse(result["ok"])
        self.assertIn("changed during capture", result["inconclusive_reason"])
        self.assertEqual(result["context_gate"]["field"], "contextSignature")

    def test_rejects_missing_capture_context_metadata(self):
        result = pce._summarize_cycles(
            [
                _cycle(100.0, include_context=False),
                _cycle(101.0),
                _cycle(102.0),
            ],
            _args(),
        )
        self.assertFalse(result["ok"])
        self.assertIn("preflight metadata", result["inconclusive_reason"])
        self.assertEqual(result["context_gate"]["field"], "preflight")

    def test_rejects_context_change_on_inconclusive_cycle(self):
        result = pce._summarize_cycles(
            [
                _cycle(100.0, context="ctx-a"),
                _cycle(None, reason="no signal", context="ctx-b"),
                _cycle(101.0, context="ctx-a"),
            ],
            _args(),
        )
        self.assertFalse(result["ok"])
        self.assertIn("route context changed", result["inconclusive_reason"])
        self.assertEqual(result["context_gate"]["field"], "contextSignature")

    def test_rejects_preflight_capture_context_mismatch(self):
        changed = _cycle(100.0, context="ctx-a")
        changed["capture"]["contextSignature"] = "ctx-b"
        result = pce._summarize_cycles(
            [changed, _cycle(101.0), _cycle(102.0)],
            _args(),
        )
        self.assertFalse(result["ok"])
        self.assertIn("between preflight and capture", result["inconclusive_reason"])
        self.assertEqual(result["context_gate"]["field"], "contextSignature")

    def test_rejects_airplay_timing_epoch_change(self):
        changed = _cycle(100.0, airplay_timing_epoch=1)
        changed["capture"]["endAirplayTimingEpoch"] = 2
        result = pce._summarize_cycles(
            [changed, _cycle(101.0), _cycle(102.0)],
            _args(),
        )
        self.assertFalse(result["ok"])
        self.assertIn("AirPlay timing epoch changed", result["inconclusive_reason"])
        self.assertEqual(result["context_gate"]["field"], "airplayTimingEpoch")

    def test_rejects_missing_microphone_timing_metadata(self):
        missing = _cycle(100.0)
        del missing["capture"]["microphoneArmedAtNs"]
        result = pce._summarize_cycles(
            [missing, _cycle(101.0), _cycle(102.0)],
            _args(),
        )
        self.assertFalse(result["ok"])
        self.assertIn("missing arm timestamp", result["inconclusive_reason"])
        self.assertEqual(result["timing_gate"]["field"], "microphoneArmedAtNs")

    def test_rejects_inconsistent_microphone_start_padding(self):
        changed = _cycle(100.0)
        changed["capture"]["microphoneFirstSampleAtNs"] = 1_000_100_000
        changed["capture"]["microphoneStartPaddingFrames"] = 0
        result = pce._summarize_cycles(
            [changed, _cycle(101.0), _cycle(102.0)],
            _args(),
        )
        self.assertFalse(result["ok"])
        self.assertIn("start padding is inconsistent", result["inconclusive_reason"])
        self.assertEqual(result["timing_gate"]["field"], "microphoneStartPaddingFrames")

    def test_strong_peak_summary_keeps_comparable_peaks(self):
        estimate = {
            "aggregate_peaks": [
                {"delay_ms": 100.0, "count": 5, "mean_score": 0.9},
                {"delay_ms": 180.0, "count": 4, "mean_score": 0.5},
                {"delay_ms": 500.0, "count": 1, "mean_score": 0.8},
                {"delay_ms": 540.0, "count": 4, "mean_score": 0.2},
            ]
        }
        result = pce._strong_peak_summary(
            estimate,
            relative_score=0.45,
            relative_count=0.5,
        )
        self.assertEqual(result["count"], 2)
        self.assertEqual(result["delays_ms"], [100.0, 180.0])
        self.assertEqual(result["spread_ms"], 80.0)

    def test_passive_status_uses_non_capture_rpc(self):
        socket_path = Path("/tmp/syncast-test.sock")
        status = {"ok": True, "currentDelayMs": 2250}
        with mock.patch.object(pce, "_json_rpc", return_value=status) as rpc:
            result = pce._passive_status(socket_path)
        self.assertEqual(result, status)
        rpc.assert_called_once_with(
            socket_path,
            "passive_status",
            {},
            timeout_sec=2.0,
        )

    def test_passive_status_ready_accepts_full_route_context(self):
        pce._check_passive_status_ready(_ready_status())

    def test_passive_status_ready_rejects_bad_status_result(self):
        with self.assertRaisesRegex(RuntimeError, "passive_status returned unexpected"):
            pce._check_passive_status_ready(_ready_status(ok=False))

    def test_passive_status_ready_rejects_unavailable_backend(self):
        for backend in ("", "unknown", "router-gone", "tap-unavailable", "new-backend"):
            with self.subTest(backend=backend):
                with self.assertRaisesRegex(RuntimeError, "backend is not ready"):
                    pce._check_passive_status_ready(_ready_status(captureBackend=backend))

    def test_passive_status_ready_rejects_missing_or_invalid_busy_state(self):
        status = _ready_status()
        del status["inProgress"]
        with self.assertRaisesRegex(RuntimeError, "busy state"):
            pce._check_passive_status_ready(status)
        with self.assertRaisesRegex(RuntimeError, "busy state"):
            pce._check_passive_status_ready(_ready_status(inProgress="false"))

    def test_passive_status_ready_rejects_explicitly_busy_capture(self):
        with self.assertRaisesRegex(RuntimeError, "already in progress"):
            pce._check_passive_status_ready(_ready_status(inProgress=True))

    def test_passive_status_ready_rejects_missing_airplay(self):
        for count in (0, None, True, "1"):
            with self.subTest(count=count):
                with self.assertRaisesRegex(RuntimeError, "enabled AirPlay"):
                    pce._check_passive_status_ready(_ready_status(enabledAirplayCount=count))

    def test_passive_status_ready_rejects_inactive_airplay(self):
        for count in (None, 0, 2, True, "1"):
            with self.subTest(count=count):
                with self.assertRaisesRegex(RuntimeError, "connected"):
                    pce._check_passive_status_ready(
                        _ready_status(enabledAirplayCount=1, activeAirplayCount=count)
                    )

    def test_passive_status_ready_rejects_missing_context(self):
        with self.assertRaisesRegex(RuntimeError, "route context is missing"):
            pce._check_passive_status_ready(_ready_status(contextSignature=""))

    def test_passive_status_ready_rejects_missing_airplay_timing_epoch(self):
        for value in (None, True, -1, "1"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(RuntimeError, "AirPlay timing epoch"):
                    pce._check_passive_status_ready(
                        _ready_status(airplayTimingEpoch=value)
                    )

    def test_passive_status_ready_rejects_unknown_sync_context_state(self):
        with self.assertRaisesRegex(RuntimeError, "sync context state is unknown"):
            pce._check_passive_status_ready(
                _ready_status(syncContextState="futureState")
            )

    def test_passive_status_ready_rejects_unavailable_capture_path(self):
        with self.assertRaisesRegex(RuntimeError, "passive capture is not available"):
            pce._check_passive_status_ready(_ready_status(passiveCaptureAvailable=False))
        status = _ready_status()
        del status["passiveCaptureAvailable"]
        with self.assertRaisesRegex(RuntimeError, "passive capture is not available"):
            pce._check_passive_status_ready(status)

    def test_main_rejects_preflight_context_change_across_cycles(self):
        captures = [
            _capture_context(context="ctx-1"),
            _capture_context(context="ctx-2"),
        ]
        estimates = [
            {"delay_ms": 100.0, "delay_mad_ms": 0.0, "mean_score": 0.5, "inconclusive_reason": None, "aggregate_peaks": []},
            {"delay_ms": 101.0, "delay_mad_ms": 0.0, "mean_score": 0.5, "inconclusive_reason": None, "aggregate_peaks": []},
        ]
        with mock.patch.object(pce, "_parse_args", return_value=_main_args()), \
             mock.patch.object(pce, "_validate_args"), \
             mock.patch.object(pce, "_check_socket_ready"), \
             mock.patch.object(
                 pce,
                 "_passive_status",
                 side_effect=[
                     _ready_status(contextSignature="ctx-1"),
                     _ready_status(contextSignature="ctx-2"),
                 ],
             ) as passive_status, \
             mock.patch.object(pce, "_capture_once", side_effect=captures), \
             mock.patch.object(pce, "_estimate_capture", side_effect=estimates), \
             mock.patch("sys.stdout", io.StringIO()) as stdout:
            rc = pce.main()

        self.assertEqual(rc, pce.EXIT_INCONCLUSIVE)
        self.assertEqual(passive_status.call_count, 2)
        result = json.loads(stdout.getvalue())
        self.assertEqual(len(result["preflights"]), 2)
        self.assertEqual(result["cycles"][0]["preflight"]["contextSignature"], "ctx-1")
        self.assertEqual(result["cycles"][1]["preflight"]["contextSignature"], "ctx-2")
        self.assertIn(
            "route context changed",
            result["summary"]["inconclusive_reason"],
        )

    def test_main_rejects_unready_status_before_capture(self):
        with mock.patch.object(pce, "_parse_args", return_value=_main_args()), \
             mock.patch.object(pce, "_validate_args"), \
             mock.patch.object(pce, "_check_socket_ready"), \
             mock.patch.object(
                 pce,
                 "_passive_status",
                 return_value=_ready_status(enabledAirplayCount=0),
             ), \
             mock.patch.object(pce, "_capture_once") as capture_once, \
             mock.patch("sys.stderr"):
            rc = pce.main()

        self.assertEqual(rc, pce.EXIT_CAPTURE_FAILED)
        capture_once.assert_not_called()

    def test_main_preflight_only_exits_before_capture(self):
        with mock.patch.object(pce, "_parse_args", return_value=_main_args(preflight_only=True)), \
             mock.patch.object(pce, "_validate_args") as validate_args, \
             mock.patch.object(pce, "_check_socket_ready") as check_socket_ready, \
             mock.patch.object(
                 pce,
                 "_passive_status",
                 return_value=_ready_status(contextSignature="ctx-ready"),
             ) as passive_status, \
             mock.patch.object(pce, "_capture_once") as capture_once, \
             mock.patch("sys.stdout", io.StringIO()) as stdout:
            rc = pce.main()

        self.assertEqual(rc, pce.EXIT_OK)
        validate_args.assert_called_once()
        check_socket_ready.assert_called_once_with(Path("/tmp/fake-syncast.sock"))
        passive_status.assert_called_once_with(Path("/tmp/fake-syncast.sock"))
        capture_once.assert_not_called()
        result = json.loads(stdout.getvalue())
        self.assertEqual(result["verdict"], "preflight_ok")
        self.assertFalse(result["opensMicrophone"])
        self.assertFalse(result["emitsAudio"])
        self.assertFalse(result["appliesDelay"])
        self.assertEqual(result["status"]["contextSignature"], "ctx-ready")

    def test_main_preflight_only_writes_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "nested" / "capture-preflight.json"
            with mock.patch.object(
                pce,
                "_parse_args",
                return_value=_main_args(preflight_only=True, report_path=report),
            ), \
                 mock.patch.object(pce, "_validate_args"), \
                 mock.patch.object(pce, "_check_socket_ready"), \
                 mock.patch.object(
                     pce,
                     "_passive_status",
                     return_value=_ready_status(contextSignature="ctx-ready"),
                 ), \
                 mock.patch.object(pce, "_capture_once") as capture_once, \
                 mock.patch("sys.stdout", io.StringIO()):
                rc = pce.main()

            self.assertEqual(rc, pce.EXIT_OK)
            capture_once.assert_not_called()
            payload = json.loads(report.read_text())
            self.assertEqual(payload["verdict"], "preflight_ok")
            self.assertEqual(payload["status"]["contextSignature"], "ctx-ready")

    def test_main_preflight_only_rejects_unready_status_before_capture(self):
        with mock.patch.object(pce, "_parse_args", return_value=_main_args(preflight_only=True)), \
             mock.patch.object(pce, "_validate_args"), \
             mock.patch.object(pce, "_check_socket_ready"), \
             mock.patch.object(
                 pce,
                 "_passive_status",
                 return_value=_ready_status(activeAirplayCount=0),
             ), \
             mock.patch.object(pce, "_capture_once") as capture_once, \
             mock.patch("sys.stderr"):
            rc = pce.main()

        self.assertEqual(rc, pce.EXIT_CAPTURE_FAILED)
        capture_once.assert_not_called()

    def test_main_writes_failure_report_before_socket(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "capture-failed.json"
            args = _main_args(
                preflight_only=True,
                report_path=report,
                socket=Path(tmp) / "missing.sock",
            )
            with mock.patch.object(pce, "_parse_args", return_value=args), \
                 mock.patch.object(pce, "_capture_once") as capture_once, \
                 mock.patch("sys.stderr", io.StringIO()):
                rc = pce.main()

            self.assertEqual(rc, pce.EXIT_CAPTURE_FAILED)
            capture_once.assert_not_called()
            payload = json.loads(report.read_text())
            self.assertEqual(payload["verdict"], "capture_failed")
            self.assertIn("socket not found", payload["error"])

    def test_validate_rejects_impossible_estimator_window(self):
        args = argparse.Namespace(
            cycles=1,
            duration_sec=4.0,
            max_delay_ms=300,
            min_ms=0.0,
            max_ms=400.0,
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
            max_mad_ms=10.0,
            cycle_cluster_radius_ms=20.0,
            max_cycle_range_ms=20.0,
            max_cycle_mad_ms=15.0,
            max_estimate_slope_ms_per_min=None,
            max_strong_peak_spread_ms=60.0,
            min_cluster_fraction=0.6,
            min_valid_reference_ratio=0.98,
            min_cycle_fraction=0.66,
            strong_peak_relative_score=0.45,
            strong_peak_relative_count=0.5,
            socket=Path("/tmp/does-not-matter"),
        )
        with self.assertRaisesRegex(ValueError, "--max-ms must be <= --max-delay-ms"):
            pce._validate_args(args)

    def test_validate_rejects_bad_estimator_args_before_socket(self):
        base = argparse.Namespace(
            cycles=1,
            duration_sec=4.0,
            max_delay_ms=3500,
            min_ms=0.0,
            max_ms=None,
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
            max_mad_ms=10.0,
            cycle_cluster_radius_ms=20.0,
            max_cycle_range_ms=20.0,
            max_cycle_mad_ms=15.0,
            max_estimate_slope_ms_per_min=None,
            max_strong_peak_spread_ms=60.0,
            min_cluster_fraction=0.6,
            min_valid_reference_ratio=0.98,
            min_cycle_fraction=0.66,
            strong_peak_relative_score=0.45,
            strong_peak_relative_count=0.5,
            socket=Path("/tmp/does-not-exist"),
        )
        cases = [
            ("window_sec", 0, "--window-sec must be > 0"),
            ("hop_sec", 0, "--hop-sec must be > 0"),
            ("min_score", -1, "--min-score must be >= 0"),
            ("min_peak_z", -1, "--min-peak-z must be >= 0"),
            ("peak_separation_ms", 0, "--peak-separation-ms must be > 0"),
        ]
        for field, value, message in cases:
            args = argparse.Namespace(**vars(base))
            setattr(args, field, value)
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, message):
                    pce._validate_args(args)


if __name__ == "__main__":
    unittest.main()
