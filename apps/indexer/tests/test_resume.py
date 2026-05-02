"""§11 end-to-end verification matrix.

Runs the real `prism-indexer scan` against the 20-track fixture
library via ``subprocess.run`` (so we exercise the worker pool, not
just the in-process pipeline). Each test corresponds to one numbered
verification item; they run in matrix order so the second-pass tests
inherit the first pass's sidecars.

This is the slice's heaviest test by wall-clock — ~3 minutes on the
reference laptop, dominated by the first-pass model load (~1 s) and
the per-track effnet inference (~1.5 s × 20 / N_workers). Marked
``slow``; gated on ``PRISM_RUN_SLOW=1`` so default `pytest -q` on a
fresh checkout doesn't pay the cost.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("essentia")

if os.environ.get("PRISM_RUN_SLOW", "0") != "1":
    pytest.skip(
        "skip slow e2e resume matrix (set PRISM_RUN_SLOW=1 to run)",
        allow_module_level=True,
    )


def _run_scan(
    library: Path, *, force: bool = False, workers: int = 2
) -> subprocess.CompletedProcess[str]:
    """Invoke the installed `prism-indexer` console script. Captures
    stdout + stderr for assertions on the run summary.
    """
    cmd = [
        sys.executable,
        "-m",
        "indexer",
        "scan",
        str(library),
        "--workers",
        str(workers),
    ]
    if force:
        cmd.append("--force")
    return subprocess.run(cmd, capture_output=True, text=True, check=True)


def _count_sidecars(library: Path) -> int:
    return len(list(library.glob("*.sonic.json")))


def _summary_field(stdout: str, label: str) -> int:
    """Pull the integer value out of one of the run-summary lines:

        analyzed   : 5
    """
    for line in stdout.splitlines():
        s = line.strip()
        if s.startswith(label):
            return int(s.split(":")[-1].strip())
    raise AssertionError(f"{label} not found in stdout:\n{stdout}")


def test_full_matrix(fresh_library: Path) -> None:
    """The §11 verification matrix end-to-end.

    All seven numbered checks run in one test so the second-pass and
    re-mux assertions can build on the first pass's sidecars. Splitting
    into separate tests would 3x the wall-clock by re-running the
    first scan from scratch each time.
    """
    library = fresh_library

    # --- §11.1 fresh scan: 20 sidecars, all valid JSON ---
    result = _run_scan(library)
    sidecar_count = _count_sidecars(library)
    assert sidecar_count == 20, (
        f"want 20 sidecars after fresh scan, got {sidecar_count}\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )
    assert _summary_field(result.stdout, "analyzed") == 20

    # Each sidecar parses as JSON with schema_version == 1.
    for sc in library.glob("*.sonic.json"):
        with open(sc, "rb") as f:
            obj = json.load(f)
        assert obj["schema_version"] == 1, sc
        assert obj["analyzer_models"] == [
            "msd-musicnn-1",
            "discogs-effnet-bs64-1",
        ]
        assert isinstance(obj["embedding"], list)
        assert len(obj["embedding"]) == 1280
        assert obj["bit_depth"] in (16, 24, None)

    # --- §11.2 re-run: 20 skips, no re-analyze, no atomic_write ---
    sidecar_mtimes_before = {
        sc.name: sc.stat().st_mtime_ns for sc in library.glob("*.sonic.json")
    }
    result = _run_scan(library)
    assert _summary_field(result.stdout, "up-to-date") == 20
    assert _summary_field(result.stdout, "analyzed") == 0
    sidecar_mtimes_after = {
        sc.name: sc.stat().st_mtime_ns for sc in library.glob("*.sonic.json")
    }
    assert sidecar_mtimes_before == sidecar_mtimes_after, (
        "no atomic_write should fire on the second pass; mtimes drifted"
    )

    # --- §11.3 touch one file: still 20 skips (mtime ≠ content) ---
    target = library / "sine_440_0.flac"
    os.utime(target, None)  # bump mtime, content unchanged
    result = _run_scan(library)
    assert _summary_field(result.stdout, "up-to-date") == 20
    assert _summary_field(result.stdout, "analyzed") == 0

    # --- §11.4 ffmpeg re-mux (tags only, PCM intact) → 20 skips ---
    re_muxed = library / "_remux_tmp.flac"
    proc = subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", str(library / "sine_440_1.flac"),
            "-metadata", "title=remuxed",
            "-c", "copy",
            str(re_muxed),
        ],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    shutil.move(str(re_muxed), str(library / "sine_440_1.flac"))
    # Drop the stale sidecar's mtime check since the re-mux changed
    # the source file's mtime — but the resume logic compares
    # audio_sha1, not mtime.
    result = _run_scan(library)
    assert _summary_field(result.stdout, "up-to-date") == 20, (
        "re-mux with -c copy preserves PCM; the indexer must skip"
    )
    assert _summary_field(result.stdout, "analyzed") == 0

    # --- §11.5 replace one file with a genuinely different recording ---
    proc = subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "lavfi",
            "-i", "sine=frequency=880:duration=2:sample_rate=44100",
            "-ac", "2",
            "-c:a", "flac",
            "-sample_fmt", "s16",
            str(library / "sine_440_2.flac"),  # filename stays, PCM differs
        ],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    result = _run_scan(library)
    assert _summary_field(result.stdout, "analyzed") == 1
    assert _summary_field(result.stdout, "up-to-date") == 19

    # --- §11.6 --force: all 20 re-analyzed regardless of state ---
    result = _run_scan(library, force=True)
    assert _summary_field(result.stdout, "analyzed") == 20
    assert _summary_field(result.stdout, "up-to-date") == 0

    # --- §11.7 sync-conflict sidecar leaves both sides untouched ---
    conflict = library / "silence_0.sync-conflict-20240101-ABCDEFG.sonic.json"
    conflict.write_text('{"poisoned": true}', encoding="utf-8")
    conflict_before = conflict.read_bytes()
    real_sidecar = library / "silence_0.sonic.json"
    real_before = real_sidecar.read_bytes()
    result = _run_scan(library)
    assert conflict.read_bytes() == conflict_before, "conflict touched"
    assert real_sidecar.read_bytes() == real_before, "real sidecar overwritten"
    # The conflict file is filtered at the walker level so it never
    # appears in the per-track summary; the 20 real tracks are all up-to-date.
    assert _summary_field(result.stdout, "up-to-date") == 20
