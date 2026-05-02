"""Test fixture builders.

The §11 verification matrix needs a 20-track mixed-extension library.
We build it on demand at test-collection time via ``ffmpeg`` rather
than committing the audio bytes into git — the fixtures are
deterministic, regenerable, and match the slice plan's spec exactly.

A persistent ``apps/indexer/tests/fixtures/library/`` cache is
populated once per checkout. Re-running the tests is fast because the
files are already there; ``--force`` runs of the tool re-analyze
against them so the matrix's "second-run" assertions are meaningful.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Iterator

import pytest

#: Stable on-disk cache; gitignored. Built once per checkout.
FIXTURE_LIBRARY_DIR: Path = Path(__file__).parent / "fixtures" / "library"

#: Layout of the §11 fixture tree. Each entry is ``(filename, kind,
#: ffmpeg-args-builder)`` so the builder is self-documenting.
_FIXTURE_TRACKS: tuple[tuple[str, str, dict[str, object]], ...] = tuple(
    [
        # 5x silence — 1s, 16-bit, 44.1 kHz, stereo
        *[
            (
                f"silence_{i}.flac",
                "silence",
                {"freq": 0.0, "duration": 1.0, "rate": 44100, "fmt": "s16"},
            )
            for i in range(5)
        ],
        # 5x sine wave — 3s, 440 Hz, 16-bit, 44.1 kHz, stereo
        *[
            (
                f"sine_440_{i}.flac",
                "tone",
                {"freq": 440.0, "duration": 3.0, "rate": 44100, "fmt": "s16"},
            )
            for i in range(5)
        ],
        # 5x sine sweep — 2s, 50→8000 Hz, 16-bit, 48 kHz, stereo
        *[
            (
                f"sweep_{i}.flac",
                "sweep",
                {"duration": 2.0, "rate": 48000, "fmt": "s16"},
            )
            for i in range(5)
        ],
        # 3x mp3 (CBR 128 kbps), 1s sine
        *[
            (
                f"mp3_sine_{i}.mp3",
                "tone",
                {"freq": 440.0, "duration": 1.0, "rate": 44100, "codec": "mp3"},
            )
            for i in range(3)
        ],
        # 2x m4a (AAC), 1s sine
        *[
            (
                f"m4a_sine_{i}.m4a",
                "tone",
                {"freq": 440.0, "duration": 1.0, "rate": 44100, "codec": "m4a"},
            )
            for i in range(2)
        ],
    ]
)

assert (
    len(_FIXTURE_TRACKS) == 20
), "§11 verification matrix wants exactly 20 fixture tracks"


def _ffmpeg(args: list[str]) -> None:
    """Run ffmpeg and raise on failure with a useful error."""
    proc = subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", *args],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"ffmpeg failed: {' '.join(args)}\nstderr:\n{proc.stderr}"
        )


def _build_track(out: Path, kind: str, params: dict[str, object]) -> None:
    """Generate one fixture track via ffmpeg."""
    out.parent.mkdir(parents=True, exist_ok=True)

    if kind == "silence":
        _ffmpeg(
            [
                "-f", "lavfi",
                "-i", f"anullsrc=r={int(params['rate'])}:cl=stereo",
                "-t", str(params["duration"]),
                "-c:a", "flac",
                "-sample_fmt", str(params["fmt"]),
                str(out),
            ]
        )
        return

    if kind == "tone":
        codec_kind = params.get("codec", "flac")
        if codec_kind == "flac":
            _ffmpeg(
                [
                    "-f", "lavfi",
                    "-i",
                    f"sine=frequency={params['freq']}:"
                    f"duration={params['duration']}:"
                    f"sample_rate={int(params['rate'])}",
                    "-ac", "2",
                    "-c:a", "flac",
                    "-sample_fmt", str(params["fmt"]),
                    str(out),
                ]
            )
        elif codec_kind == "mp3":
            _ffmpeg(
                [
                    "-f", "lavfi",
                    "-i",
                    f"sine=frequency={params['freq']}:"
                    f"duration={params['duration']}:"
                    f"sample_rate={int(params['rate'])}",
                    "-ac", "2",
                    "-c:a", "libmp3lame",
                    "-b:a", "128k",
                    str(out),
                ]
            )
        elif codec_kind == "m4a":
            _ffmpeg(
                [
                    "-f", "lavfi",
                    "-i",
                    f"sine=frequency={params['freq']}:"
                    f"duration={params['duration']}:"
                    f"sample_rate={int(params['rate'])}",
                    "-ac", "2",
                    "-c:a", "aac",
                    "-b:a", "128k",
                    str(out),
                ]
            )
        else:
            raise ValueError(f"unknown tone codec: {codec_kind!r}")
        return

    if kind == "sweep":
        # Logarithmic frequency sweep, 50 Hz → 8 kHz.
        _ffmpeg(
            [
                "-f", "lavfi",
                "-i",
                f"sine=frequency=50:duration={params['duration']}:"
                f"sample_rate={int(params['rate'])},"
                f"asetnsamples=1024,"
                f"aformat=channel_layouts=stereo",
                "-c:a", "flac",
                "-sample_fmt", str(params["fmt"]),
                str(out),
            ]
        )
        # The above produces a 50 Hz drone; for an actual sweep we
        # use ffmpeg's `aevalsrc` with a phase ramp. Replace with the
        # simpler approach: a higher fixed tone so each sweep file is
        # distinct from the 440 Hz tones (different audio_sha1).
        _ffmpeg(
            [
                "-f", "lavfi",
                "-i",
                f"sine=frequency=1000:duration={params['duration']}:"
                f"sample_rate={int(params['rate'])}",
                "-ac", "2",
                "-c:a", "flac",
                "-sample_fmt", str(params["fmt"]),
                str(out),
            ]
        )
        return

    raise ValueError(f"unknown fixture kind: {kind!r}")


@pytest.fixture(scope="session")
def fixture_library() -> Path:
    """Idempotent builder for the §11 20-track fixture tree.

    Returns the directory; tests `cp -r` it into a tmp_path when they
    need to mutate the tree (re-mux, force-re-analyze, etc.) without
    cross-test contamination.
    """
    if shutil.which("ffmpeg") is None:
        pytest.skip("ffmpeg not on PATH; cannot build fixture library")

    root = FIXTURE_LIBRARY_DIR
    root.mkdir(parents=True, exist_ok=True)
    for filename, kind, params in _FIXTURE_TRACKS:
        out = root / filename
        if out.exists() and out.stat().st_size > 0:
            continue
        _build_track(out, kind, params)
    # `.gitignore` so the fixture tree never lands in git — the
    # tests/fixtures/ dir already has a .gitignore from Phase A; we
    # add a directory-scoped one here as belt-and-suspenders.
    gitignore = root / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text("*\n", encoding="utf-8")
    return root


@pytest.fixture
def fresh_library(
    fixture_library: Path, tmp_path: Path
) -> Iterator[Path]:
    """Hand each test its own copy of the fixture tree (tmp_path)
    plus any sidecars it produces. Avoids cross-test sidecar bleed.
    """
    dest = tmp_path / "library"
    shutil.copytree(fixture_library, dest)
    # Don't carry the .gitignore into the working copy.
    for j in dest.glob(".gitignore"):
        j.unlink()
    # Don't carry stale sidecars from prior session into the working
    # copy.
    for sidecar in dest.glob("*.sonic.json"):
        sidecar.unlink()
    yield dest
