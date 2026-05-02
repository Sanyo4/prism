"""Verifies streaming audio_sha1 produces deterministic digests over
PCM and rejects unsupported input shapes.
"""

from __future__ import annotations

import numpy as np
import pytest

from indexer.hashing import audio_sha1


def test_one_second_silence_is_deterministic() -> None:
    silence = np.zeros(44100, dtype=np.float32)
    digest_a = audio_sha1(silence)
    digest_b = audio_sha1(silence.copy())
    assert digest_a == digest_b
    assert len(digest_a) == 40
    assert all(c in "0123456789abcdef" for c in digest_a)


def test_flipping_one_sample_changes_digest() -> None:
    pcm = np.zeros(1024, dtype=np.float32)
    base = audio_sha1(pcm)
    pcm[512] = 1.0
    flipped = audio_sha1(pcm)
    assert base != flipped


def test_long_input_uses_streaming_chunks() -> None:
    """A 30-second 96 kHz stream is ~10 MB — larger than the 1 MiB
    chunk size, so the streaming path is exercised. Result must be
    stable across two calls.
    """
    n = 30 * 96000
    pcm = np.linspace(-1.0, 1.0, n, dtype=np.float32)
    a = audio_sha1(pcm)
    b = audio_sha1(pcm.copy())
    assert a == b


def test_rejects_2d_input() -> None:
    pcm = np.zeros((2, 1024), dtype=np.float32)
    with pytest.raises(ValueError, match="1-D mono"):
        audio_sha1(pcm)


def test_rejects_non_float32() -> None:
    pcm = np.zeros(1024, dtype=np.float64)
    with pytest.raises(ValueError, match="float32"):
        audio_sha1(pcm)
