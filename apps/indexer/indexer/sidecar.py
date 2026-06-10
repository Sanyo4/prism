"""``SidecarV1`` dataclass + ``to_json_bytes`` serializer.

The on-disk format is locked by ``docs/spec.md`` § "Sidecar format".
Field order in :py:meth:`SidecarV1.to_json_bytes` is hand-specified
(not alphabetical, not :py:func:`dataclasses.asdict` order) so reviewers
eyeballing diffs see fields in the same order across machines.

The slice 4 reader will tolerate unknown keys (per spec versioning
rules), but slice 3 emits a strict subset.

**Plan/spec deviation note** — the slice plan and `docs/spec.md`
reference the model name ``"musicnn-msd-2"``, but Essentia's upstream
publishes only ``msd-musicnn-1.pb``. We use the upstream-actual
identifier so the resume check matches what the model files on disk
identify as. A future spec edit can rename without invalidating any
sidecar (additive field changes, plus a string-rename in this constant
that triggers a one-time re-analysis on every existing sidecar — the
intended cost of analyzer model changes).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Final, Literal

#: Schema version emitted in every sidecar. Bumping this in a future
#: slice forces re-analysis of every existing sidecar (the resume
#: check in ``pipeline.analyze`` compares this field). Per spec
#: versioning rules: bump only on breaking reader changes — additive
#: optional fields never require a bump.
CURRENT_SCHEMA_VERSION: Final[int] = 1

#: Analyzer identity string. Tracks the Essentia wheel version we
#: validate against; bumping the wheel without changing this is fine
#: as long as algorithm output is byte-stable.
ANALYZER_ID: Final[str] = "essentia-2.1-beta6-dev"

#: Model identifiers. Order matches the JSON output. Slice 4's resume
#: check on the Flutter side compares this tuple against the sidecar's
#: ``analyzer_models`` field — a mismatch (length or contents) marks
#: the sidecar stale.
ANALYZER_MODELS: Final[tuple[str, ...]] = (
    "msd-musicnn-1",
    "discogs-effnet-bs64-1",
)


@dataclass(frozen=True, slots=True)
class MoodVector:
    """Five mood probabilities from the MSD-musicnn classifier head.

    Range is ``[0.0, 1.0]`` per dimension; values are independent
    sigmoid outputs (not a softmax) so they don't sum to 1.
    """

    happy: float
    sad: float
    aggressive: float
    relaxed: float
    party: float

    def to_dict(self) -> dict[str, float]:
        return {
            "happy": self.happy,
            "sad": self.sad,
            "aggressive": self.aggressive,
            "relaxed": self.relaxed,
            "party": self.party,
        }


@dataclass(frozen=True, slots=True)
class SidecarV1:
    """Immutable record of one analysis pass, serialized as
    ``<track>.sonic.json`` next to the source audio.

    All fields are required. ``to_json_bytes`` is the only sanctioned
    serializer — direct ``json.dumps`` of ``__dict__`` would lose
    field order and break the spec contract.
    """

    schema_version: int
    analyzer: str
    analyzer_models: tuple[str, ...]

    # File identity (stable across tag edits, unstable across re-encoding).
    audio_sha1: str
    duration_sec: float
    sample_rate: int
    bit_depth: int | None  # None for lossy sources

    # Rhythm + tonality.
    bpm: float
    bpm_confidence: float
    key: str  # e.g. "Fm", "C#", "Bbm"
    key_confidence: float

    # Loudness (LUFS) + ReplayGain (track-/album-equal until slice 4
    # re-groups by album).
    loudness_lufs: float
    replaygain_track_db: float
    replaygain_album_db: float

    # Spectral / categorical.
    spectral_centroid_mean: float
    danceability: float  # 0..1
    mood: MoodVector
    genre_top3: tuple[tuple[str, float], ...]  # exactly 3 entries
    voice_instrumental: float  # 1.0 = fully instrumental

    # Embedding from the discogs-effnet-bs64-1 penultimate layer.
    embedding_model: Literal["discogs-effnet-bs64-1"]
    embedding: tuple[float, ...]  # length 1280

    def __post_init__(self) -> None:
        # Strict validation at construction time so analysis bugs are
        # caught before they hit disk. Frozen dataclass prevents post-
        # construction mutation.
        if self.schema_version != CURRENT_SCHEMA_VERSION:
            raise ValueError(
                f"schema_version must be {CURRENT_SCHEMA_VERSION}, "
                f"got {self.schema_version}"
            )
        if len(self.audio_sha1) != 40:
            raise ValueError(
                f"audio_sha1 must be 40 hex chars (lowercase), "
                f"got {len(self.audio_sha1)}: {self.audio_sha1!r}"
            )
        if len(self.genre_top3) != 3:
            raise ValueError(
                f"genre_top3 must have exactly 3 entries, "
                f"got {len(self.genre_top3)}"
            )
        if len(self.embedding) != 1280:
            raise ValueError(
                f"embedding must be length 1280, got {len(self.embedding)}"
            )
        if self.embedding_model != "discogs-effnet-bs64-1":
            raise ValueError(
                "embedding_model must be 'discogs-effnet-bs64-1', "
                f"got {self.embedding_model!r}"
            )

    def to_dict(self) -> dict[str, object]:
        """Build a Python dict in the spec field order. Helper for
        ``to_json_bytes`` — also useful in tests for shape assertions
        without round-tripping through JSON.

        Insertion order is preserved by Python ≥3.7's dict semantics,
        so the JSON serializer below renders fields in this order.
        """
        return {
            "schema_version": self.schema_version,
            "analyzer": self.analyzer,
            "analyzer_models": list(self.analyzer_models),
            "audio_sha1": self.audio_sha1,
            "duration_sec": self.duration_sec,
            "sample_rate": self.sample_rate,
            "bit_depth": self.bit_depth,
            "bpm": self.bpm,
            "bpm_confidence": self.bpm_confidence,
            "key": self.key,
            "key_confidence": self.key_confidence,
            "loudness_lufs": self.loudness_lufs,
            "replaygain_track_db": self.replaygain_track_db,
            "replaygain_album_db": self.replaygain_album_db,
            "spectral_centroid_mean": self.spectral_centroid_mean,
            "danceability": self.danceability,
            "mood": self.mood.to_dict(),
            "genre_top3": [list(g) for g in self.genre_top3],
            "voice_instrumental": self.voice_instrumental,
            "embedding_model": self.embedding_model,
            "embedding": list(self.embedding),
        }

    def to_json_bytes(self) -> bytes:
        """Serialize the sidecar to UTF-8 bytes. No trailing newline,
        no key sorting (spec field order wins), ``ensure_ascii=False``
        so non-Latin keys (none today, but safe) round-trip.
        """
        return json.dumps(
            self.to_dict(),
            ensure_ascii=False,
            separators=(", ", ": "),
        ).encode("utf-8")


def read_existing(path: str) -> SidecarV1 | None:
    """Read and parse an existing sidecar.

    Returns ``None`` when:
      - the file does not exist;
      - the file is malformed JSON;
      - any required field is missing or the wrong type.

    Unknown fields are tolerated (forward-compat) — only the keys
    slice 3 itself emits are validated. The result is a fully-typed
    ``SidecarV1`` for the resume-check in ``pipeline.analyze``.
    """
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return None
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(obj, dict):
        return None
    try:
        mood = obj["mood"]
        return SidecarV1(
            schema_version=int(obj["schema_version"]),
            analyzer=str(obj["analyzer"]),
            analyzer_models=tuple(obj["analyzer_models"]),
            audio_sha1=str(obj["audio_sha1"]),
            duration_sec=float(obj["duration_sec"]),
            sample_rate=int(obj["sample_rate"]),
            bit_depth=(
                int(obj["bit_depth"]) if obj.get("bit_depth") is not None else None
            ),
            bpm=float(obj["bpm"]),
            bpm_confidence=float(obj["bpm_confidence"]),
            key=str(obj["key"]),
            key_confidence=float(obj["key_confidence"]),
            loudness_lufs=float(obj["loudness_lufs"]),
            replaygain_track_db=float(obj["replaygain_track_db"]),
            replaygain_album_db=float(obj["replaygain_album_db"]),
            spectral_centroid_mean=float(obj["spectral_centroid_mean"]),
            danceability=float(obj["danceability"]),
            mood=MoodVector(
                happy=float(mood["happy"]),
                sad=float(mood["sad"]),
                aggressive=float(mood["aggressive"]),
                relaxed=float(mood["relaxed"]),
                party=float(mood["party"]),
            ),
            genre_top3=tuple(
                (str(g[0]), float(g[1])) for g in obj["genre_top3"]
            ),
            voice_instrumental=float(obj["voice_instrumental"]),
            embedding_model=str(obj["embedding_model"]),  # type: ignore[arg-type]
            embedding=tuple(float(x) for x in obj["embedding"]),
        )
    except (KeyError, TypeError, ValueError):
        return None
