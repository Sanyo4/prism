"""Step 9 integration tests: the TF-classifier path (musicnn + effnet
predictions + 1280-d embedding). Heavy by slice-3 standards — needs
the real ~22 MB of `.pb` files in `~/.cache/prism/models/` and a
loaded TensorFlow.

Marked ``slow``; gated on ``PRISM_RUN_SLOW=1`` so default `pytest -q`
on a fresh checkout doesn't pay the model-load cost. The §11 e2e
test in `test_resume.py` covers the same ground with a worker-pool
scan; this file is a focused component test.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

pytest.importorskip("essentia")

if os.environ.get("PRISM_RUN_SLOW", "0") != "1":
    pytest.skip(
        "skip slow classifier test (set PRISM_RUN_SLOW=1 to run)",
        allow_module_level=True,
    )


@pytest.fixture(scope="module")
def loaded_models() -> object:
    from indexer.models import ensure_models

    return ensure_models()


def test_classifiers_emit_full_mood_and_embedding(
    fixture_library: Path, loaded_models
) -> None:
    """End-to-end: decode → 16k → classifiers → packed sidecar fields.
    Asserts shape + range invariants, not specific tag probabilities
    (those drift across Essentia minor versions).
    """
    import math

    from indexer.pipeline import _load_pcm_16k, _run_classifiers

    pcm_16k = _load_pcm_16k(str(fixture_library / "sine_440_0.flac"))
    mood, genre_top3, voice_instr, embedding = _run_classifiers(
        pcm_16k, loaded_models
    )

    # MoodVector — five floats in [0, 1] (sigmoid outputs).
    for name in ("happy", "sad", "aggressive", "relaxed", "party"):
        v = getattr(mood, name)
        assert math.isfinite(v)
        assert 0.0 <= v <= 1.0, f"{name}={v!r} out of [0,1]"

    # Genre top-3: exactly 3 entries, each (label, prob), descending.
    assert len(genre_top3) == 3
    probs = [p for _, p in genre_top3]
    assert probs == sorted(probs, reverse=True)
    for label, prob in genre_top3:
        assert isinstance(label, str) and label
        assert 0.0 <= prob <= 1.0

    # voice_instrumental — same range.
    assert 0.0 <= voice_instr <= 1.0

    # Embedding — 1280-d Python floats (json-serializable).
    assert len(embedding) == 1280
    assert all(isinstance(v, float) and math.isfinite(v) for v in embedding[:16])


def test_resolve_msd_indices_finds_known_tags() -> None:
    """The pre-resolution maps MSD vocabulary → mood-group columns.
    Confirms the expected tags exist in the upstream vocabulary; if
    a future model bump renames them, this test fails loud.
    """
    from indexer.pipeline import _resolve_msd_indices
    from indexer.models import ensure_models

    classes = ensure_models().musicnn_classes
    groups, instr_idx = _resolve_msd_indices(classes)

    assert groups["happy"] != ()
    assert groups["sad"] != ()
    assert groups["party"] != ()
    # Aggressive/relaxed are derived from groups; expect at least one
    # match per group (vocabulary covers `metal`, `chill`, etc.).
    assert groups["aggressive"] != ()
    assert groups["relaxed"] != ()
    assert instr_idx is not None
