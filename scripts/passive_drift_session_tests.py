#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


def _write_fake_python(path: Path) -> None:
    path.write_text(
        textwrap.dedent(
            r"""#!/usr/bin/env bash
            set -euo pipefail

            prog="${1:-}"
            if [[ "$prog" == "-c" || "$prog" == "-" ]]; then
              exec "$SYNCAST_REAL_PYTHON" "$@"
            fi
            base="$(basename "$prog")"
            printf '%s\n' "$base" >> "$SYNCAST_FAKE_PYTHON_LOG"

            output=""
            prev=""
            for arg in "$@"; do
              if [[ "$prev" == "--output" || "$prev" == "--report-path" ]]; then
                output="$arg"
              fi
              prev="$arg"
            done

            write_json() {
              local path="$1"
              local payload="$2"
              mkdir -p "$(dirname "$path")"
              printf '%s\n' "$payload" > "$path"
            }

            case "$base" in
              passive_readiness_report.py)
                write_json "$output" '{"schema":"syncast.passive_readiness.v1","verdict":"ready","recommendedWorkflow":"apply_dry_run","recommendedSessionMode":"apply_dry_run","passiveEvidenceIntent":"dry_run_candidate","passiveEvidenceIntentSource":"app_status","opensMicrophone":false,"emitsAudio":false,"appliesDelay":false}'
                exit 0
                ;;
              passive_workflow_guard.py)
                write_json "$output" '{"schema":"syncast.passive_workflow_guard.v1","verdict":"blocked","reason":"apply_dry_run_requires_existing_ready_session","opensMicrophone":false,"emitsAudio":false,"appliesDelay":false}'
                exit 3
                ;;
              passive_session_audit.py)
                printf '%s\n' '{"verdict":"capture_failed","phase":"workflow_guard","opensMicrophone":false,"emitsAudio":false,"appliesDelay":false}'
                exit 3
                ;;
              passive_control_report.py)
                write_json "$output" '{"verdict":"capture_failed","phase":"workflow_guard","blockingStage":"workflow_guard","opensMicrophone":false,"emitsAudio":false,"appliesDelay":false}'
                exit 3
                ;;
              passive_capture_estimate.py|passive_drift_monitor.py)
                touch "$SYNCAST_FAKE_CAPTURE_CALLED"
                exit 99
                ;;
              *)
                echo "unexpected fake python target: $base" >&2
                exit 97
                ;;
            esac
            """
        )
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class PassiveDriftSessionWrapperTests(unittest.TestCase):
    def test_readiness_only_stops_before_workflow_guard_or_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            fake_python = bin_dir / "python3"
            _write_fake_python(fake_python)

            output_root = tmp_path / "session"
            invocation_log = tmp_path / "fake-python.log"
            capture_marker = tmp_path / "capture-called"
            env = {
                **os.environ,
                "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
                "SYNCAST_FAKE_PYTHON_LOG": str(invocation_log),
                "SYNCAST_FAKE_CAPTURE_CALLED": str(capture_marker),
                "SYNCAST_REAL_PYTHON": sys.executable,
                "SYNCAST_PASSIVE_READINESS_ONLY": "1",
            }
            result = subprocess.run(
                [
                    "bash",
                    "scripts/passive_drift_session.sh",
                    "1",
                    "1",
                    "1",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
            manifest = json.loads((output_root / "manifest.json").read_text())
            self.assertTrue(manifest["readinessOnly"])
            self.assertTrue((output_root / "readiness.json").exists())
            self.assertTrue((output_root / "control_report.json").exists())
            self.assertFalse((output_root / "workflow_guard.json").exists())
            self.assertFalse((output_root / "capture_preflight.json").exists())
            self.assertFalse((output_root / "preflight.json").exists())
            self.assertFalse((output_root / "monitor.json").exists())
            self.assertFalse(capture_marker.exists())
            self.assertEqual(
                invocation_log.read_text().splitlines(),
                [
                    "passive_readiness_report.py",
                    "passive_readiness_report.py",
                    "passive_control_report.py",
                ],
            )

    def test_workflow_guard_block_stops_before_capture_preflight_or_monitor(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            fake_python = bin_dir / "python3"
            _write_fake_python(fake_python)

            output_root = tmp_path / "session"
            invocation_log = tmp_path / "fake-python.log"
            capture_marker = tmp_path / "capture-called"
            env = {
                **os.environ,
                "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
                "SYNCAST_FAKE_PYTHON_LOG": str(invocation_log),
                "SYNCAST_FAKE_CAPTURE_CALLED": str(capture_marker),
                "SYNCAST_REAL_PYTHON": sys.executable,
                "SYNCAST_PASSIVE_WORKFLOW_GUARD": "enforce",
            }
            result = subprocess.run(
                [
                    "bash",
                    "scripts/passive_drift_session.sh",
                    "1",
                    "1",
                    "1",
                    str(output_root),
                ],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
            workflow_guard = json.loads(
                (output_root / "workflow_guard.json").read_text()
            )
            self.assertEqual(workflow_guard["verdict"], "blocked")
            self.assertFalse((output_root / "capture_preflight.json").exists())
            self.assertFalse((output_root / "preflight.json").exists())
            self.assertFalse((output_root / "monitor.json").exists())
            self.assertFalse((output_root / "samples.jsonl").exists())
            self.assertFalse(capture_marker.exists())
            self.assertEqual(
                invocation_log.read_text().splitlines(),
                [
                    "passive_readiness_report.py",
                    "passive_readiness_report.py",
                    "passive_workflow_guard.py",
                    "passive_session_audit.py",
                    "passive_control_report.py",
                ],
            )


if __name__ == "__main__":
    unittest.main()
