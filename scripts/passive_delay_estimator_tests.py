#!/usr/bin/env python3
"""Regression tests for scripts/passive_delay_estimator.py.

These tests are deliberately offline-only: they synthesize arrays or tiny WAV
fixtures in a temporary directory and never touch CoreAudio or SyncCast.
"""

from __future__ import annotations

import importlib.util
import contextlib
import io
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock

import numpy as np


SCRIPT = Path(__file__).with_name("passive_delay_estimator.py")
SPEC = importlib.util.spec_from_file_location("passive_delay_estimator", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
passive = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = passive
SPEC.loader.exec_module(passive)


def make_reference(sample_rate: int = 16_000, duration_s: float = 8.0) -> np.ndarray:
    rng = np.random.default_rng(424242)
    n = int(sample_rate * duration_s)
    t = np.arange(n, dtype=np.float32) / float(sample_rate)
    noise = rng.normal(0, 0.16, n).astype(np.float32)
    envelope = (0.45 + 0.55 * np.sin(2 * np.pi * 0.73 * t) ** 2).astype(np.float32)
    signal = noise * envelope
    signal += 0.05 * np.sin(2 * np.pi * 330 * t)
    signal += 0.03 * np.sin(2 * np.pi * 1320 * t)
    return signal.astype(np.float32)


def delayed(signal: np.ndarray, sample_rate: int, delay_ms: float) -> np.ndarray:
    delay_samples = int(round(sample_rate * delay_ms / 1000.0))
    out = np.zeros_like(signal)
    if delay_samples < signal.size:
        out[delay_samples:] = signal[: signal.size - delay_samples]
    return out


def estimate(reference: np.ndarray, microphone: np.ndarray, sample_rate: int, **kwargs):
    params = {
        "min_ms": 0.0,
        "max_ms": 700.0,
        "mode": "waveform",
        "window_s": 2.0,
        "hop_s": 1.0,
        "min_rms": 0.0005,
        "min_score": 0.04,
        "min_prominence": 1.02,
        "peak_separation_ms": 20.0,
        "cluster_radius_ms": 10.0,
        "min_cluster_fraction": 0.60,
        "max_mad_ms": 10.0,
    }
    params.update(kwargs)
    return passive.estimate_delay(reference, microphone, sample_rate, **params)


def fake_feature_result(
    *,
    delay_ms: float | None,
    windows: tuple[tuple[float, float], ...],
    slope_ms_per_min: float = 0.0,
    reason: str | None = None,
    path_candidates: list[dict] | None = None,
) -> dict:
    return {
        "delay_ms": delay_ms,
        "delay_mad_ms": 0.0 if delay_ms is not None else None,
        "inconclusive_reason": reason,
        "windows_considered": len(windows),
        "windows_total": len(windows),
        "windows_accepted": len(windows),
        "windows_clustered": len(windows),
        "accepted_window_fraction": 1.0 if windows else 0.0,
        "path_candidate_windows": len(windows),
        "slope_ms_per_min": slope_ms_per_min,
        "drift_ppm": slope_ms_per_min * 1000.0 / 60.0,
        "fitted_drift_span_ms": slope_ms_per_min * max(len(windows) - 1, 0) / 60.0,
        "drift_residual_mad_ms": 0.0,
        "drift_window_span_s": max(len(windows) - 1, 0),
        "mean_score": 0.5,
        "median_prominence": 1.5,
        "median_peak_z": 8.0,
        "aggregate_peaks": [],
        "path_candidates": path_candidates or [],
        "accepted_windows": [
            {
                "ref_start_s": ref_start_s,
                "delay_ms": window_delay_ms,
                "score": 0.5,
                "prominence": 1.5,
                "peak_z": 8.0,
            }
            for ref_start_s, window_delay_ms in windows
        ],
    }


class PassiveDelayEstimatorTests(unittest.TestCase):
    def test_recovers_delay_with_slow_mic_bias(self) -> None:
        sr = 16_000
        reference = make_reference(sr)
        t = np.arange(reference.size, dtype=np.float32) / float(sr)
        microphone = 0.8 * delayed(reference, sr, 237.0)
        microphone += 0.08 * np.sin(2 * np.pi * 0.25 * t).astype(np.float32)

        result = estimate(reference, microphone, sr, min_ms=50, max_ms=500)

        self.assertIsNotNone(result["delay_ms"])
        self.assertLess(abs(result["delay_ms"] - 237.0), 5.0)
        self.assertLessEqual(result["delay_mad_ms"], 1.0)
        self.assertLess(abs(result["slope_ms_per_min"]), 1.0)

    def test_dual_mode_requires_waveform_envelope_agreement(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=10.0)
        microphone = 0.8 * delayed(reference, sr, 237.0)

        result = estimate(
            reference,
            microphone,
            sr,
            min_ms=50,
            max_ms=500,
            mode="dual",
        )

        self.assertIsNotNone(result["delay_ms"])
        self.assertLess(abs(result["delay_ms"] - 237.0), 5.0)
        self.assertTrue(result["feature_agreement"]["ok"])
        self.assertLessEqual(result["feature_agreement"]["delta_ms"], 25.0)

    def test_dual_mode_rejects_feature_disagreement(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=10.0)
        microphone = 0.8 * delayed(reference, sr, 237.0)

        result = estimate(
            reference,
            microphone,
            sr,
            min_ms=50,
            max_ms=500,
            mode="dual",
            max_feature_delta_ms=1.0,
        )

        self.assertIsNone(result["delay_ms"])
        self.assertIn("feature delay disagreement", result["inconclusive_reason"])

    def test_dual_mode_caps_feature_delta_by_mad_gate(self) -> None:
        waveform = fake_feature_result(
            delay_ms=200.0,
            windows=((0.0, 200.0), (1.0, 200.0), (2.0, 200.0)),
        )
        envelope = fake_feature_result(
            delay_ms=224.0,
            windows=((0.0, 224.0), (1.0, 224.0), (2.0, 224.0)),
        )
        with mock.patch.object(
            passive,
            "_estimate_delay_single",
            side_effect=[waveform, envelope],
        ):
            result = estimate(
                np.zeros(100, dtype=np.float32),
                np.zeros(100, dtype=np.float32),
                16_000,
                mode="dual",
                max_feature_delta_ms=25.0,
                max_mad_ms=10.0,
            )

        self.assertIsNone(result["delay_ms"])
        self.assertEqual(result["feature_agreement"]["max_delta_ms"], 20.0)
        self.assertIn("feature delay disagreement", result["inconclusive_reason"])

    def test_dual_mode_requires_overlapping_feature_windows(self) -> None:
        waveform = fake_feature_result(
            delay_ms=200.0,
            windows=((0.0, 200.0), (1.0, 200.0), (2.0, 200.0)),
        )
        envelope = fake_feature_result(
            delay_ms=200.0,
            windows=((10.0, 200.0), (11.0, 200.0), (12.0, 200.0)),
        )
        with mock.patch.object(
            passive,
            "_estimate_delay_single",
            side_effect=[waveform, envelope],
        ):
            result = estimate(
                np.zeros(100, dtype=np.float32),
                np.zeros(100, dtype=np.float32),
                16_000,
                mode="dual",
            )

        self.assertIsNone(result["delay_ms"])
        self.assertIn("feature window overlap too sparse", result["inconclusive_reason"])

    def test_dual_mode_reports_worst_absolute_slope_for_gating(self) -> None:
        waveform = fake_feature_result(
            delay_ms=200.0,
            slope_ms_per_min=120.0,
            windows=((0.0, 200.0), (1.0, 200.0), (2.0, 200.0)),
        )
        envelope = fake_feature_result(
            delay_ms=200.0,
            slope_ms_per_min=-130.0,
            windows=((0.0, 200.0), (1.0, 200.0), (2.0, 200.0)),
        )
        with mock.patch.object(
            passive,
            "_estimate_delay_single",
            side_effect=[waveform, envelope],
        ):
            result = estimate(
                np.zeros(100, dtype=np.float32),
                np.zeros(100, dtype=np.float32),
                16_000,
                mode="dual",
            )

        self.assertEqual(result["delay_ms"], 200.0)
        self.assertEqual(result["slope_ms_per_min"], -130.0)
        self.assertEqual(result["drift_slope_source"], "envelope")

    def test_dual_mode_path_candidates_require_feature_agreement(self) -> None:
        waveform = fake_feature_result(
            delay_ms=200.0,
            windows=((0.0, 200.0), (1.0, 200.0), (2.0, 200.0)),
            path_candidates=[
                {
                    "delay_ms": 200.0,
                    "delay_mad_ms": 0.0,
                    "window_count": 3,
                    "window_fraction": 1.0,
                    "mean_score": 0.7,
                    "max_score": 0.8,
                },
                {
                    "delay_ms": 410.0,
                    "delay_mad_ms": 0.0,
                    "window_count": 3,
                    "window_fraction": 1.0,
                    "mean_score": 0.6,
                    "max_score": 0.7,
                },
            ],
        )
        envelope = fake_feature_result(
            delay_ms=200.0,
            windows=((0.0, 200.0), (1.0, 200.0), (2.0, 200.0)),
            path_candidates=[
                {
                    "delay_ms": 202.0,
                    "delay_mad_ms": 1.0,
                    "window_count": 3,
                    "window_fraction": 1.0,
                    "mean_score": 0.5,
                    "max_score": 0.6,
                }
            ],
        )
        with mock.patch.object(
            passive,
            "_estimate_delay_single",
            side_effect=[waveform, envelope],
        ):
            result = estimate(
                np.zeros(100, dtype=np.float32),
                np.zeros(100, dtype=np.float32),
                16_000,
                mode="dual",
            )

        self.assertEqual(result["delay_ms"], 200.0)
        self.assertEqual(len(result["path_candidates"]), 1)
        candidate = result["path_candidates"][0]
        self.assertEqual(candidate["delay_ms"], 201.0)
        self.assertEqual(candidate["feature_delta_ms"], 2.0)
        self.assertEqual(candidate["mean_score"], 0.5)
        self.assertEqual(
            result["feature_agreement"]["waveform_path_candidates"],
            2,
        )
        self.assertEqual(
            result["feature_agreement"]["envelope_path_candidates"],
            1,
        )
        self.assertEqual(
            result["feature_agreement"]["agreed_path_candidates"],
            1,
        )

    def test_dual_mode_drops_all_waveform_only_path_candidates(self) -> None:
        waveform = fake_feature_result(
            delay_ms=200.0,
            windows=((0.0, 200.0), (1.0, 200.0), (2.0, 200.0)),
            path_candidates=[
                {
                    "delay_ms": 410.0,
                    "delay_mad_ms": 0.0,
                    "window_count": 3,
                    "window_fraction": 1.0,
                    "mean_score": 0.6,
                    "max_score": 0.7,
                }
            ],
        )
        envelope = fake_feature_result(
            delay_ms=200.0,
            windows=((0.0, 200.0), (1.0, 200.0), (2.0, 200.0)),
            path_candidates=[],
        )
        with mock.patch.object(
            passive,
            "_estimate_delay_single",
            side_effect=[waveform, envelope],
        ):
            result = estimate(
                np.zeros(100, dtype=np.float32),
                np.zeros(100, dtype=np.float32),
                16_000,
                mode="dual",
            )

        self.assertEqual(result["delay_ms"], 200.0)
        self.assertEqual(result["path_candidates"], [])
        self.assertEqual(
            result["feature_agreement"]["agreed_path_candidates"],
            0,
        )

    def test_cli_defaults_to_dual_mode(self) -> None:
        args = passive.parse_args([])
        self.assertEqual(args.mode, "dual")

    def test_delay_at_search_boundaries_is_eligible(self) -> None:
        sr = 16_000
        reference = make_reference(sr)
        for expected, min_ms, max_ms in (
            (0.0, 0.0, 300.0),
            (100.0, 100.0, 500.0),
            (500.0, 100.0, 500.0),
        ):
            with self.subTest(expected=expected):
                microphone = delayed(reference, sr, expected)
                result = estimate(
                    reference,
                    microphone,
                    sr,
                    min_ms=min_ms,
                    max_ms=max_ms,
                )
                self.assertIsNotNone(result["delay_ms"])
                self.assertLess(abs(result["delay_ms"] - expected), 5.0)

    def test_bimodal_windows_fail_closed(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=10.0)
        mic_a = delayed(reference, sr, 100.0)
        mic_b = delayed(reference, sr, 500.0)
        microphone = mic_a.copy()
        microphone[microphone.size // 2 :] = mic_b[microphone.size // 2 :]

        result = estimate(
            reference,
            microphone,
            sr,
            min_ms=0,
            max_ms=700,
            window_s=2.0,
            hop_s=2.0,
            min_cluster_fraction=0.7,
        )

        self.assertIsNone(result["delay_ms"])
        self.assertIn("dominant delay cluster", result["inconclusive_reason"])

    def test_cli_rejects_bad_inputs_cleanly(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            missing = passive.main(
                [
                    "--reference",
                    "/private/tmp/syncast-missing-reference.wav",
                    "--microphone",
                    "/private/tmp/syncast-missing-microphone.wav",
                ]
            )
            bad_window = passive.main(
                [
                    "--reference",
                    "/private/tmp/a.wav",
                    "--microphone",
                    "/private/tmp/b.wav",
                    "--window-sec",
                    "0",
                ]
            )
        self.assertEqual(passive.EXIT_NO_DATA, missing)
        self.assertEqual(passive.EXIT_NO_DATA, bad_window)
        self.assertIn("No such file", stderr.getvalue())
        self.assertIn("--window-sec must be > 0", stderr.getvalue())

    def test_reads_stereo_pcm16_wav_as_mono_average(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "stereo.wav"
            samples = np.array([[0.5, -0.5], [0.25, 0.25]], dtype=np.float32)
            pcm = np.clip(samples * 32767, -32768, 32767).astype("<i2")
            with wave.open(str(path), "wb") as handle:
                handle.setnchannels(2)
                handle.setsampwidth(2)
                handle.setframerate(16_000)
                handle.writeframes(pcm.tobytes())

            sample_rate, mono = passive._read_pcm_wav(path, None)

        self.assertEqual(sample_rate, 16_000)
        self.assertEqual(mono.shape, (2,))
        self.assertAlmostEqual(float(mono[0]), 0.0, places=5)
        self.assertAlmostEqual(float(mono[1]), 0.25, places=4)

    def test_reports_multiple_stable_path_candidates(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=9.0)
        microphone = 0.72 * delayed(reference, sr, 120.0)
        microphone += 0.46 * delayed(reference, sr, 360.0)

        result = estimate(
            reference,
            microphone,
            sr,
            min_ms=0,
            max_ms=600,
            min_prominence=1.0,
            min_cluster_fraction=0.5,
        )
        candidates = result["path_candidates"]
        self.assertGreaterEqual(len(candidates), 2)
        delays = sorted(item["delay_ms"] for item in candidates[:3])
        self.assertTrue(any(abs(delay - 120.0) < 10.0 for delay in delays))
        self.assertTrue(any(abs(delay - 360.0) < 10.0 for delay in delays))
        self.assertGreaterEqual(candidates[0]["window_fraction"], 0.5)

    def test_ambiguous_equal_paths_still_report_diagnostic_candidates(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=9.0)
        microphone = 0.58 * delayed(reference, sr, 150.0)
        microphone += 0.58 * delayed(reference, sr, 370.0)

        result = estimate(
            reference,
            microphone,
            sr,
            min_ms=0,
            max_ms=600,
            min_prominence=1.5,
            min_cluster_fraction=0.5,
        )

        self.assertIsNone(result["delay_ms"])
        self.assertGreaterEqual(result["path_candidate_windows"], 2)
        candidates = result["path_candidates"]
        self.assertGreaterEqual(len(candidates), 2)
        delays = sorted(item["delay_ms"] for item in candidates[:3])
        self.assertTrue(any(abs(delay - 150.0) < 10.0 for delay in delays))
        self.assertTrue(any(abs(delay - 370.0) < 10.0 for delay in delays))

    def test_unrelated_microphone_audio_fails_peak_z_gate(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=9.0)
        rng = np.random.default_rng(20260513)
        microphone = rng.normal(0, 0.16, reference.size).astype(np.float32)

        result = estimate(
            reference,
            microphone,
            sr,
            min_ms=0,
            max_ms=700,
            min_score=0.0,
            min_prominence=1.0,
            min_peak_z=8.0,
        )

        self.assertIsNone(result["delay_ms"])
        self.assertIn("no accepted windows", result["inconclusive_reason"])
        self.assertEqual(result["path_candidate_windows"], 0)
        self.assertGreater(result["windows_total"], 0)

    def test_unrelated_microphone_audio_fails_default_gates(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=9.0)
        rng = np.random.default_rng(20260513)
        microphone = rng.normal(0, 0.16, reference.size).astype(np.float32)

        result = estimate(reference, microphone, sr, min_ms=0, max_ms=700)

        self.assertIsNone(result["delay_ms"])
        self.assertIsNotNone(result["inconclusive_reason"])
        self.assertEqual(result["path_candidate_windows"], 0)

    def test_recovers_delay_under_loud_uncorrelated_background(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=10.0)
        rng = np.random.default_rng(20260513)
        microphone = 0.65 * delayed(reference, sr, 242.0)
        microphone += rng.normal(0, 0.18, reference.size).astype(np.float32)

        result = estimate(reference, microphone, sr, min_ms=50, max_ms=500)

        self.assertIsNotNone(result["delay_ms"])
        self.assertLess(abs(result["delay_ms"] - 242.0), 5.0)
        self.assertGreaterEqual(
            result["accepted_window_fraction"],
            result["min_accepted_window_fraction"],
        )

    def test_single_path_with_background_does_not_create_spurious_paths(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=10.0)
        rng = np.random.default_rng(20260513)
        microphone = 0.75 * delayed(reference, sr, 188.0)
        microphone += rng.normal(0, 0.08, reference.size).astype(np.float32)

        result = estimate(reference, microphone, sr, min_ms=50, max_ms=500)

        self.assertIsNotNone(result["delay_ms"])
        delays = [item["delay_ms"] for item in result["path_candidates"]]
        self.assertTrue(any(abs(delay - 188.0) < 10.0 for delay in delays))
        self.assertLessEqual(len(result["path_candidates"]), 1)

    def test_sparse_program_match_fails_accepted_window_fraction_gate(self) -> None:
        sr = 16_000
        reference = make_reference(sr, duration_s=10.0)
        rng = np.random.default_rng(20260513)
        microphone = delayed(reference, sr, 211.0)
        cutoff = int(sr * 3.0)
        microphone[cutoff:] = rng.normal(
            0,
            0.16,
            microphone.size - cutoff,
        ).astype(np.float32)

        result = estimate(
            reference,
            microphone,
            sr,
            min_ms=0,
            max_ms=700,
            min_score=0.02,
            min_prominence=1.0,
            min_peak_z=6.0,
            min_cluster_fraction=0.5,
            min_accepted_window_fraction=0.75,
        )

        self.assertIsNone(result["delay_ms"])
        self.assertIn("accepted window fraction", result["inconclusive_reason"])
        self.assertLess(
            result["accepted_window_fraction"],
            result["min_accepted_window_fraction"],
        )
        self.assertGreater(result["windows_clustered"], 0)


if __name__ == "__main__":
    unittest.main()
