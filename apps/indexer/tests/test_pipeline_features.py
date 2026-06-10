"""Step 8 unit tests: feature-extraction (rhythm, key, loudness,
centroid, danceability) against deterministic sine fixtures. We
assert the values are *finite + plausible* rather than exact —
Essentia's algorithms have their own tuning and we don't want to
pin numeric output across wheel revisions.
"""

from __future__ import annotations

import math
from pathlib import Path

import pytest

pytest.importorskip("essentia")


def test_extract_features_sine_440_finite_values(fixture_library: Path) -> None:
    from indexer.pipeline import _decode, _extract_features

    pcm, sr, _bd = _decode(str(fixture_library / "sine_440_0.flac"))
    features = _extract_features(pcm, sr)

    # Every scalar field is finite — non-finite would crash the
    # JSON serializer at sidecar-write time.
    for k in (
        "bpm",
        "bpm_confidence",
        "key_confidence",
        "loudness_lufs",
        "replaygain_track_db",
        "replaygain_album_db",
        "spectral_centroid_mean",
        "danceability",
    ):
        v = features[k]
        assert isinstance(v, float)
        assert math.isfinite(v), f"{k} is not finite: {v!r}"

    # BPM > 0 even for a sine wave (RhythmExtractor2013 will hallucinate
    # a tempo from the periodic envelope).
    assert features["bpm"] > 0
    # 440 Hz sine → A. Allow ANY enharmonic equivalent + scale because
    # KeyExtractor's certainty on a pure sine is low; we just confirm
    # the field is a non-empty string.
    assert isinstance(features["key"], str) and features["key"]
    # Spectral centroid for a 440 Hz tone should be in the low end of
    # the spectrum, well under 5 kHz.
    assert 0 < features["spectral_centroid_mean"] < 5000.0
    # Danceability is normalized to [0, 1] per spec.
    assert 0.0 <= features["danceability"] <= 1.0
    # ReplayGain is the spec's -18 LUFS reference minus integrated.
    assert features["replaygain_track_db"] == pytest.approx(
        -18.0 - features["loudness_lufs"], rel=1e-9, abs=1e-6
    )
    # Album RG mirrors track RG until slice 4 re-groups by album.
    assert features["replaygain_album_db"] == features["replaygain_track_db"]


def test_extract_features_silence_clamps_loudness(fixture_library: Path) -> None:
    """Silence drives EBU R128 to either ``-inf`` or its internal
    ``-70`` LUFS floor (depending on input length / windowing).
    Either way the pipeline must produce a JSON-finite scalar; we
    clamp ``-inf`` to ``-120`` dB and pass other negative values
    through unchanged.
    """
    from indexer.pipeline import _decode, _extract_features

    pcm, sr, _bd = _decode(str(fixture_library / "silence_0.flac"))
    features = _extract_features(pcm, sr)
    assert math.isfinite(features["loudness_lufs"])
    # Silence ≤ -60 LUFS — well below the typical -14 LUFS streaming
    # target. Essentia's internal floor is -70 LUFS for very short
    # clips, so we don't pin a tighter bound.
    assert features["loudness_lufs"] <= -60.0


def test_extract_features_48k_sweep_resamples_for_rhythm(
    fixture_library: Path,
) -> None:
    """The 48 kHz sweep exercises the resample-to-44.1k branch in
    RhythmExtractor2013. Just confirms the path doesn't blow up and
    yields a finite BPM.
    """
    from indexer.pipeline import _decode, _extract_features

    pcm, sr, _bd = _decode(str(fixture_library / "sweep_0.flac"))
    assert sr == 48000
    features = _extract_features(pcm, sr)
    assert math.isfinite(features["bpm"])
    assert features["bpm"] > 0


def test_format_key_major_minor_shapes() -> None:
    """The ``_format_key`` helper turns Essentia's (root, scale) into
    the spec's ``"Fm"`` / ``"C#"`` / ``"Bbm"`` strings.
    """
    from indexer.pipeline import _format_key

    assert _format_key("C", "major") == "C"
    assert _format_key("F", "minor") == "Fm"
    assert _format_key("C#", "major") == "C#"
    assert _format_key("Bb", "minor") == "Bbm"
