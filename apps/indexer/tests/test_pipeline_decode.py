"""Step 7 unit tests: AudioLoader-driven decode + channel-mean
to mono float32. Heavy deps gated behind `pytest.importorskip`
so the test file collects on machines without the analysis extra.
"""

from __future__ import annotations

from pathlib import Path

import pytest

pytest.importorskip("essentia")  # skip whole module if no analysis extra


def test_decode_silent_flac_returns_mono_float32(fixture_library: Path) -> None:
    import numpy as np

    from indexer.pipeline import _decode

    pcm, sr, bit_depth = _decode(str(fixture_library / "silence_0.flac"))
    assert pcm.ndim == 1, f"want mono 1D PCM, got shape {pcm.shape}"
    assert pcm.dtype == np.float32
    assert sr == 44100
    assert bit_depth == 16
    # 1 second of silence at 44.1 kHz → 44_100 samples, give or take
    # a few ffmpeg-padded zeros at the boundary.
    assert 44_000 <= pcm.shape[0] <= 44_200, pcm.shape
    # Silence: every sample within float32 quantization noise.
    assert float(np.max(np.abs(pcm))) < 1e-3


def test_decode_sine_flac_native_44k(fixture_library: Path) -> None:
    import numpy as np

    from indexer.pipeline import _decode

    pcm, sr, bit_depth = _decode(str(fixture_library / "sine_440_0.flac"))
    assert pcm.ndim == 1
    assert pcm.dtype == np.float32
    assert sr == 44100
    assert bit_depth == 16
    # 3 s @ 44.1 kHz; AudioLoader rounds to the codec's frame boundary.
    assert 132_000 <= pcm.shape[0] <= 132_500, pcm.shape
    # Sine is clearly non-silent (ffmpeg's default sine generator
    # peaks ~0.09 in float; threshold low enough to discriminate
    # against silence at ~1e-4 but well above quantization noise).
    assert float(np.max(np.abs(pcm))) > 0.05


def test_decode_sine_flac_48k_sweep(fixture_library: Path) -> None:
    """Sweeps were generated at 48 kHz to cover the non-44.1k path
    (RhythmExtractor2013 needs 44.1k input; the pipeline resamples).
    """
    from indexer.pipeline import _decode

    pcm, sr, _bit_depth = _decode(str(fixture_library / "sweep_0.flac"))
    assert sr == 48000
    # 2 s @ 48 kHz ≈ 96 000 samples
    assert 95_500 <= pcm.shape[0] <= 96_500, pcm.shape


def test_decode_lossy_mp3_has_no_bit_depth(fixture_library: Path) -> None:
    """Spec semantics: lossy codecs return ``bit_depth=None``."""
    from indexer.pipeline import _decode

    pcm, sr, bit_depth = _decode(str(fixture_library / "mp3_sine_0.mp3"))
    assert bit_depth is None
    assert sr == 44100
    assert pcm.size > 0


def test_decode_missing_file_raises(tmp_path: Path) -> None:
    from indexer.pipeline import _decode

    with pytest.raises(Exception):
        _decode(str(tmp_path / "does-not-exist.flac"))
