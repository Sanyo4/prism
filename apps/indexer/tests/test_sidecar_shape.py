"""Verifies SidecarV1 produces JSON in the docs/spec.md field order
and validates its inputs at construction time.

We don't import a copy of the spec example as a fixture — instead the
test re-creates the canonical record from the same constants the
indexer uses, then asserts on key ordering + value round-trip.
"""

from __future__ import annotations

import json

import pytest

from indexer import (
    ANALYZER_ID,
    ANALYZER_MODELS,
    CURRENT_SCHEMA_VERSION,
    SidecarV1,
)
from indexer.sidecar import MoodVector, read_existing


def _canonical_sidecar() -> SidecarV1:
    """Build a fully-populated SidecarV1 mirroring docs/spec.md's
    example block (with model name corrected to upstream-actual).
    """
    return SidecarV1(
        schema_version=CURRENT_SCHEMA_VERSION,
        analyzer=ANALYZER_ID,
        analyzer_models=ANALYZER_MODELS,
        audio_sha1="ab" * 20,  # 40 hex chars
        duration_sec=234.5,
        sample_rate=96000,
        bit_depth=24,
        bpm=118.4,
        bpm_confidence=0.88,
        key="Fm",
        key_confidence=0.74,
        loudness_lufs=-14.2,
        replaygain_track_db=3.1,
        replaygain_album_db=3.4,
        spectral_centroid_mean=1832.0,
        danceability=0.61,
        mood=MoodVector(
            happy=0.22, sad=0.67, aggressive=0.08, relaxed=0.71, party=0.14
        ),
        genre_top3=(
            ("indie rock", 0.41),
            ("alternative", 0.22),
            ("shoegaze", 0.14),
        ),
        voice_instrumental=0.88,
        embedding_model="discogs-effnet-bs64-1",
        embedding=tuple([0.013] * 1280),
    )


def test_field_order_matches_spec() -> None:
    """The exact ordering matters because spec.md shows it and slice-4
    review will diff sidecars by hand.
    """
    sc = _canonical_sidecar()
    payload = sc.to_json_bytes()
    obj = json.loads(payload)
    assert list(obj.keys()) == [
        "schema_version",
        "analyzer",
        "analyzer_models",
        "audio_sha1",
        "duration_sec",
        "sample_rate",
        "bit_depth",
        "bpm",
        "bpm_confidence",
        "key",
        "key_confidence",
        "loudness_lufs",
        "replaygain_track_db",
        "replaygain_album_db",
        "spectral_centroid_mean",
        "danceability",
        "mood",
        "genre_top3",
        "voice_instrumental",
        "embedding_model",
        "embedding",
    ]


def test_mood_renders_as_nested_object() -> None:
    sc = _canonical_sidecar()
    obj = json.loads(sc.to_json_bytes())
    assert obj["mood"] == {
        "happy": 0.22,
        "sad": 0.67,
        "aggressive": 0.08,
        "relaxed": 0.71,
        "party": 0.14,
    }


def test_genre_top3_renders_as_list_of_pairs() -> None:
    sc = _canonical_sidecar()
    obj = json.loads(sc.to_json_bytes())
    assert obj["genre_top3"] == [
        ["indie rock", 0.41],
        ["alternative", 0.22],
        ["shoegaze", 0.14],
    ]


def test_no_trailing_newline_in_payload() -> None:
    sc = _canonical_sidecar()
    payload = sc.to_json_bytes()
    assert not payload.endswith(b"\n")


def test_lossy_source_omits_bit_depth_value() -> None:
    sc = _canonical_sidecar()
    sc_lossy = SidecarV1(
        schema_version=sc.schema_version,
        analyzer=sc.analyzer,
        analyzer_models=sc.analyzer_models,
        audio_sha1=sc.audio_sha1,
        duration_sec=sc.duration_sec,
        sample_rate=44100,
        bit_depth=None,
        bpm=sc.bpm,
        bpm_confidence=sc.bpm_confidence,
        key=sc.key,
        key_confidence=sc.key_confidence,
        loudness_lufs=sc.loudness_lufs,
        replaygain_track_db=sc.replaygain_track_db,
        replaygain_album_db=sc.replaygain_album_db,
        spectral_centroid_mean=sc.spectral_centroid_mean,
        danceability=sc.danceability,
        mood=sc.mood,
        genre_top3=sc.genre_top3,
        voice_instrumental=sc.voice_instrumental,
        embedding_model=sc.embedding_model,
        embedding=sc.embedding,
    )
    obj = json.loads(sc_lossy.to_json_bytes())
    assert obj["bit_depth"] is None


@pytest.mark.parametrize(
    ("kwargs", "expected_substring"),
    [
        ({"audio_sha1": "x" * 39}, "40 hex"),
        ({"genre_top3": (("a", 1.0), ("b", 1.0))}, "exactly 3 entries"),
        ({"embedding": tuple([0.0] * 256)}, "length 1280"),
        ({"schema_version": 99}, "schema_version must be 1"),
        ({"embedding_model": "wrong"}, "embedding_model"),
    ],
)
def test_validation_at_construction(
    kwargs: dict[str, object], expected_substring: str
) -> None:
    """`SidecarV1.__post_init__` rejects malformed values *before*
    they hit disk. Each row pokes one bad field.
    """
    base = _canonical_sidecar()
    base_kwargs: dict[str, object] = {
        "schema_version": base.schema_version,
        "analyzer": base.analyzer,
        "analyzer_models": base.analyzer_models,
        "audio_sha1": base.audio_sha1,
        "duration_sec": base.duration_sec,
        "sample_rate": base.sample_rate,
        "bit_depth": base.bit_depth,
        "bpm": base.bpm,
        "bpm_confidence": base.bpm_confidence,
        "key": base.key,
        "key_confidence": base.key_confidence,
        "loudness_lufs": base.loudness_lufs,
        "replaygain_track_db": base.replaygain_track_db,
        "replaygain_album_db": base.replaygain_album_db,
        "spectral_centroid_mean": base.spectral_centroid_mean,
        "danceability": base.danceability,
        "mood": base.mood,
        "genre_top3": base.genre_top3,
        "voice_instrumental": base.voice_instrumental,
        "embedding_model": base.embedding_model,
        "embedding": base.embedding,
    }
    base_kwargs.update(kwargs)
    with pytest.raises(ValueError, match=expected_substring):
        SidecarV1(**base_kwargs)  # type: ignore[arg-type]


def test_read_existing_round_trips(tmp_path) -> None:
    sc = _canonical_sidecar()
    target = tmp_path / "song.sonic.json"
    target.write_bytes(sc.to_json_bytes())
    parsed = read_existing(str(target))
    assert parsed is not None
    assert parsed.audio_sha1 == sc.audio_sha1
    assert parsed.bpm == sc.bpm
    assert parsed.mood.sad == sc.mood.sad
    assert parsed.genre_top3 == sc.genre_top3
    assert len(parsed.embedding) == 1280


def test_read_existing_returns_none_on_missing(tmp_path) -> None:
    assert read_existing(str(tmp_path / "nope.sonic.json")) is None


def test_read_existing_returns_none_on_malformed(tmp_path) -> None:
    target = tmp_path / "bad.sonic.json"
    target.write_text("not json {{{")
    assert read_existing(str(target)) is None


def test_read_existing_tolerates_unknown_fields(tmp_path) -> None:
    """Forward-compat: a slice-4 sidecar with extra fields must still
    parse cleanly under slice 3.
    """
    sc = _canonical_sidecar()
    obj = json.loads(sc.to_json_bytes())
    obj["future_field_we_haven't_invented"] = "ok"
    target = tmp_path / "future.sonic.json"
    target.write_bytes(json.dumps(obj).encode("utf-8"))
    parsed = read_existing(str(target))
    assert parsed is not None
    assert parsed.audio_sha1 == sc.audio_sha1
