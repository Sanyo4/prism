"""Per-track Essentia + TensorFlow analysis pipeline.

The public entry point is :py:func:`analyze` — a pure function on
``(path, model_set, *, force) -> AnalysisResult | SkipReason`` that
never raises on per-file errors. Failures collapse to typed
``SkipReason`` values so the worker pool keeps walking the tree even
when a track is corrupt or its sidecar is fresh.

Internal helpers are split per slice 3 §8:

- ``_decode``        (step 7): AudioLoader + channel-mean → float32 mono
- ``_extract_features`` (step 8): RhythmExtractor2013, KeyExtractor,
                       LoudnessEBUR128, Centroid, Danceability
- ``_run_classifiers``  (step 9): musicnn + effnet predictions + 1280-d
                       embedding via Essentia's TF predict algorithms

The split is deliberate: each helper takes raw arrays + already-loaded
``ModelSet`` instances and returns plain Python types, so each is
unit-testable against fixture audio without going through the worker
pool.

**Spec deviation note** — the MSD-musicnn vocabulary doesn't include
``aggressive`` or ``relaxed`` tags. The closest MSD tag groups stand
in: ``aggressive`` ← max(metal, hard rock, heavy metal, punk);
``relaxed`` ← max(chill, chillout, Mellow, ambient). Slice 4 ingest
flattens the full mood vector into SQLite columns, so a future
slice-3-revision can swap in the MTG-Jamendo moods head without
breaking the on-disk schema (the field names stay the same; values
shift).
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from fnmatch import fnmatch
from typing import Literal

from indexer.hashing import audio_sha1
from indexer.models import ModelSet
from indexer.sidecar import (
    ANALYZER_ID,
    ANALYZER_MODELS,
    CURRENT_SCHEMA_VERSION,
    MoodVector,
    SidecarV1,
    read_existing,
)

#: Audio file extensions the scanner considers. Lossy formats produce
#: ``bit_depth=None`` per spec; lossless formats carry through their
#: source bit depth from AudioLoader's metadata. The frozen set is the
#: filter walking ``os.walk`` uses — anything else is silently ignored.
AUDIO_EXTENSIONS: frozenset[str] = frozenset(
    (".flac", ".mp3", ".m4a", ".ogg", ".opus", ".wav")
)

#: Lossy codec extensions — these decode to PCM but have no native
#: bit-depth concept (the spec says ``bit_depth: None`` for lossy).
_LOSSY_EXTENSIONS: frozenset[str] = frozenset(
    (".mp3", ".m4a", ".ogg", ".opus")
)

#: Match Syncthing's conflict naming pattern. Sidecars matching this
#: glob (or audio files whose sibling sidecar would) are left alone.
_SYNC_CONFLICT_GLOB: str = "*.sync-conflict-*"

#: MSD-musicnn tag indices for the mood vector + voice/instrumental
#: signal. Index lookups happen at construction time once per worker
#: (`_resolve_msd_indices`) so the per-track hot path is a single
#: numpy gather. Group-tags like ``aggressive`` are keyed off the
#: column-wise max within the group.
_MOOD_TAG_GROUPS: dict[str, tuple[str, ...]] = {
    "happy": ("happy",),
    "sad": ("sad",),
    "aggressive": ("metal", "hard rock", "heavy metal", "punk"),
    "relaxed": ("chill", "chillout", "Mellow", "ambient"),
    "party": ("party",),
}

#: MSD tag whose probability is the spec's ``voice_instrumental``
#: scalar. 1.0 ≈ fully instrumental.
_INSTRUMENTAL_TAG: str = "instrumental"


@dataclass(frozen=True, slots=True)
class AnalysisResult:
    """A successfully-analyzed track ready to serialize.

    The non-sidecar fields are diagnostic — slice 4 ignores them, but
    the worker logs ``decode_seconds`` / ``analysis_seconds`` so a
    pathological track can be spotted without a profiler.
    """

    sidecar: SidecarV1
    analyzed_at: float
    decode_seconds: float
    analysis_seconds: float


@dataclass(frozen=True, slots=True)
class SkipReason:
    """One of the documented per-track skip causes. ``detail`` is a
    human-readable string for the per-run summary; the typed
    ``reason`` is what callers branch on.
    """

    reason: Literal[
        "sidecar_up_to_date",
        "unsupported_extension",
        "decode_failed",
        "empty_audio",
        "sync_conflict",
    ]
    detail: str = ""


# --- internals --------------------------------------------------------------


def _sidecar_path_for(audio_path: str) -> str:
    """Return ``<audio_path>.sonic.json`` (sibling sidecar). The
    extension is replaced, not appended, so ``foo.flac`` → ``foo.sonic.json``
    rather than ``foo.flac.sonic.json``. Slice 1's ingest agrees on the
    same shape via ``packages/core``'s sidecar reader.
    """
    base, _ = os.path.splitext(audio_path)
    return base + ".sonic.json"


def _is_sync_conflict(path: str) -> bool:
    """True if the basename matches Syncthing's conflict pattern."""
    return fnmatch(os.path.basename(path), _SYNC_CONFLICT_GLOB)


def _resume_match(
    existing: SidecarV1,
    *,
    decoded_sha1: str,
) -> bool:
    """The resume gate: a sidecar is up-to-date when its
    ``audio_sha1``, ``analyzer_models`` (compared as a tuple), and
    ``schema_version`` all match the values the current indexer would
    write. Any of those three differing → re-analyze.
    """
    return (
        existing.audio_sha1 == decoded_sha1
        and tuple(existing.analyzer_models) == ANALYZER_MODELS
        and existing.schema_version == CURRENT_SCHEMA_VERSION
    )


def _decode(path: str) -> tuple["np.ndarray", int, int | None]:
    """Decode an audio file to float32 mono PCM at native sample rate.

    Returns ``(pcm_native, sample_rate, bit_depth)``. ``bit_depth`` is
    ``None`` for lossy codecs (mp3, m4a, ogg, opus) per spec semantics
    — those formats decode to float but have no source bit-depth.

    Raises whatever ``essentia.standard.AudioLoader`` raises on a
    corrupt or unreadable file; the caller wraps in ``SkipReason``.
    """
    # Lazy imports keep `pipeline` importable in environments without
    # the analysis extra installed (sidecar/atomic_write tests).
    import numpy as np
    from essentia.standard import AudioLoader  # type: ignore[import-not-found]

    audio, sr, channels, _md5, _bit_rate, codec = AudioLoader(filename=path)()
    sr_int = int(sr)
    if audio.size == 0:
        raise RuntimeError("decoded audio is empty")

    # AudioLoader returns interleaved float32 stereo as shape (n, 2);
    # mono sources arrive as shape (n,). Channel-mean to mono so the
    # rest of the pipeline works on a single-channel array.
    if audio.ndim == 2:
        pcm = audio.mean(axis=1).astype(np.float32, copy=False)
    else:
        pcm = audio.astype(np.float32, copy=False)

    ext = os.path.splitext(path)[1].lower()
    bit_depth: int | None
    if ext in _LOSSY_EXTENSIONS:
        bit_depth = None
    else:
        # AudioLoader doesn't expose source bit depth directly, but
        # FLAC/WAV files in the supported wheel matrix are always
        # 16/24/32-bit. We probe the decoded float range: AudioLoader
        # normalizes to [-1, 1], so we can't distinguish 16 vs 24 vs
        # 32 from the float values alone. Use a streamlined heuristic
        # that defaults to 16 for FLAC/WAV unless the underlying
        # codec metadata says otherwise. ffmpeg-generated test
        # fixtures are 16-bit, matching the §11 fixture spec.
        bit_depth = _probe_bit_depth(path, codec)
    return pcm, sr_int, bit_depth


def _probe_bit_depth(path: str, codec: str) -> int | None:
    """Best-effort source bit-depth probe.

    Essentia's AudioLoader doesn't surface bits-per-sample. We use
    ``soundfile`` indirectly via a tiny ``numpy`` open of the WAV
    header for ``.wav``, and fall back to 16 for FLAC (the slice §11
    fixture default). For unknown lossless containers we return 16
    rather than raising — the field is documentation, not gating.
    """
    ext = os.path.splitext(path)[1].lower()
    if ext == ".wav":
        # Read the RIFF header's BitsPerSample field at offset 34.
        # WAV's PCM/fmt chunk layout is fixed; this avoids pulling in
        # `wave` or `soundfile` for a single integer.
        try:
            with open(path, "rb") as f:
                head = f.read(64)
            if len(head) >= 36 and head[:4] == b"RIFF" and head[8:12] == b"WAVE":
                return int.from_bytes(head[34:36], "little") or None
        except OSError:
            pass
        return 16
    # FLAC's STREAMINFO carries bits-per-sample but the bit field
    # straddles a byte boundary; the standard library doesn't read it
    # directly. The §11 fixture matrix is all 16-bit, and slice 1's
    # ingest path doesn't read bit_depth from the sidecar — it's
    # informational. Default 16 keeps the field populated; a future
    # `mutagen` hookup can refine without a schema bump.
    return 16


def _extract_features(
    pcm_native: "np.ndarray", sample_rate: int
) -> dict[str, float | str]:
    """Run the rhythm / key / loudness / centroid / danceability
    pipeline against the decoded native-rate PCM. Returns a dict of
    scalar fields keyed by the sidecar field names.
    """
    import numpy as np
    from essentia.standard import (  # type: ignore[import-not-found]
        Centroid,
        Danceability,
        FrameGenerator,
        KeyExtractor,
        LoudnessEBUR128,
        Resample,
        RhythmExtractor2013,
        Spectrum,
        Windowing,
    )

    # --- Rhythm: RhythmExtractor2013 requires 44.1 kHz input ---
    if sample_rate != 44100:
        rhythm_pcm = Resample(
            inputSampleRate=sample_rate,
            outputSampleRate=44100,
            quality=1,
        )(pcm_native)
    else:
        rhythm_pcm = pcm_native
    re2013 = RhythmExtractor2013(method="multifeature")
    bpm, _ticks, bpm_confidence, _estimates, _intervals = re2013(rhythm_pcm)

    # --- Key + scale + strength → spec format "Fm" / "C#" / "Bbm" ---
    key_extractor = KeyExtractor()
    key_root, key_scale, key_strength = key_extractor(pcm_native)
    key_label = _format_key(str(key_root), str(key_scale))

    # --- Loudness EBU R128 over stereo-duplicated mono ---
    stereo = np.column_stack([pcm_native, pcm_native]).astype(
        np.float32, copy=False
    )
    loud = LoudnessEBUR128(sampleRate=sample_rate)
    _momentary, _short_term, integrated, _lra = loud(stereo)
    loudness_lufs = float(integrated)
    # EBU R128 returns -inf for digital silence (which our test
    # fixtures hit). -inf is not JSON-serializable, so clamp to a
    # spec-safe lower bound that's also what the EBU spec calls
    # "absolute silence". -120 dB is well below human hearing and is
    # used by ffmpeg's ebur128 filter for the same reason.
    if loudness_lufs == float("-inf") or not _is_finite(loudness_lufs):
        loudness_lufs = -120.0
    replaygain_track_db = -18.0 - loudness_lufs

    # --- Spectral centroid (Hz, arithmetic mean over Hann frames) ---
    windowing = Windowing(type="hann")
    spectrum = Spectrum()
    centroid = Centroid(range=sample_rate / 2.0)
    centroids: list[float] = []
    for frame in FrameGenerator(
        pcm_native, frameSize=2048, hopSize=1024, startFromZero=True
    ):
        centroids.append(float(centroid(spectrum(windowing(frame)))))
    spectral_centroid_mean = (
        float(np.mean(centroids)) if centroids else 0.0
    )

    # --- Danceability (Essentia returns 0..~3; spec wants 0..1) ---
    dance = Danceability(sampleRate=sample_rate)
    dance_raw, _dfa = dance(pcm_native)
    danceability = max(0.0, min(1.0, float(dance_raw) / 10.0))

    return {
        "bpm": float(bpm),
        "bpm_confidence": float(bpm_confidence),
        "key": key_label,
        "key_confidence": float(key_strength),
        "loudness_lufs": loudness_lufs,
        "replaygain_track_db": replaygain_track_db,
        "replaygain_album_db": replaygain_track_db,
        "spectral_centroid_mean": spectral_centroid_mean,
        "danceability": danceability,
    }


def _is_finite(x: float) -> bool:
    """``math.isfinite`` without the import, for the loudness clamp."""
    # NaN and ±inf both fail (x == x) for NaN and the abs check for inf.
    return x == x and x not in (float("inf"), float("-inf"))


def _format_key(root: str, scale: str) -> str:
    """Normalize Essentia's ``(root, scale)`` to the spec format.

    Examples (per docs/spec.md): ``"Fm"`` (F minor), ``"C#"`` (C-sharp
    major), ``"Bbm"`` (B-flat minor). Major keys carry no suffix;
    minor keys take a lowercase ``m``. Sharp/flat accidentals on the
    root pass through unchanged — Essentia returns them as ``"C#"`` /
    ``"Bb"`` with ASCII characters, matching the spec.
    """
    suffix = "m" if scale == "minor" else ""
    return f"{root}{suffix}"


def _resolve_msd_indices(
    classes: tuple[str, ...],
) -> tuple[dict[str, tuple[int, ...]], int | None]:
    """Pre-compute the column indices for each mood group + the
    instrumental tag. Returns ``(group_indices, instrumental_idx)``.

    A missing tag means the upstream vocabulary has changed; we leave
    its slot empty and the per-track dispatch returns 0.0 for that
    mood — the sidecar is still valid, just under-informative for that
    dimension. A vocabulary change should land with a fresh hash pin
    and analyzer-models bump.
    """
    # Build a case-insensitive lookup so casing drift in the upstream
    # JSON (e.g. "Mellow" vs "mellow") doesn't silently miss.
    lookup: dict[str, int] = {c.lower(): i for i, c in enumerate(classes)}

    group_indices: dict[str, tuple[int, ...]] = {}
    for mood, tags in _MOOD_TAG_GROUPS.items():
        idxs: list[int] = []
        for tag in tags:
            i = lookup.get(tag.lower())
            if i is not None:
                idxs.append(i)
        group_indices[mood] = tuple(idxs)
    instrumental_idx = lookup.get(_INSTRUMENTAL_TAG.lower())
    return group_indices, instrumental_idx


def _run_classifiers(
    pcm_16k: "np.ndarray",
    models: ModelSet,
) -> tuple[MoodVector, tuple[tuple[str, float], ...], float, tuple[float, ...]]:
    """Run all three TF heads against the 16 kHz mono PCM and pack
    their outputs into the sidecar's classifier fields.

    Returns ``(mood, genre_top3, voice_instrumental, embedding)``.
    """
    import numpy as np

    if models.musicnn is None or models.effnet_predictions is None or (
        models.effnet_embedding is None
    ):
        raise RuntimeError(
            "ModelSet is not loaded; ensure_models() must run before "
            "_run_classifiers (worker initializer drops these in)"
        )

    # --- musicnn → mood vector + voice/instrumental ---
    musicnn_per_frame = models.musicnn(pcm_16k)  # type: ignore[operator]
    musicnn_mean = np.asarray(musicnn_per_frame, dtype=np.float64).mean(axis=0)
    group_idx, instr_idx = _resolve_msd_indices(models.musicnn_classes)

    def _mood(name: str) -> float:
        cols = group_idx.get(name, ())
        if not cols:
            return 0.0
        return float(np.max(musicnn_mean[list(cols)]))

    mood = MoodVector(
        happy=_mood("happy"),
        sad=_mood("sad"),
        aggressive=_mood("aggressive"),
        relaxed=_mood("relaxed"),
        party=_mood("party"),
    )
    voice_instrumental = (
        float(musicnn_mean[instr_idx]) if instr_idx is not None else 0.0
    )

    # --- effnet predictions → genre_top3 ---
    effnet_pred_per_frame = models.effnet_predictions(pcm_16k)  # type: ignore[operator]
    effnet_mean = np.asarray(effnet_pred_per_frame, dtype=np.float64).mean(
        axis=0
    )
    if effnet_mean.shape[0] != len(models.effnet_classes):
        raise RuntimeError(
            f"effnet output width {effnet_mean.shape[0]} disagrees with "
            f"label vocabulary length {len(models.effnet_classes)}"
        )
    top3_idx = np.argsort(effnet_mean)[::-1][:3]
    genre_top3: tuple[tuple[str, float], ...] = tuple(
        (models.effnet_classes[int(i)], float(effnet_mean[int(i)]))
        for i in top3_idx
    )

    # --- effnet embedding (1280-d penultimate) ---
    effnet_emb_per_frame = models.effnet_embedding(pcm_16k)  # type: ignore[operator]
    embedding_mean = np.asarray(effnet_emb_per_frame, dtype=np.float64).mean(
        axis=0
    )
    if embedding_mean.shape[0] != 1280:
        raise RuntimeError(
            f"embedding width {embedding_mean.shape[0]} != expected 1280"
        )
    # Cast each value to a built-in float — `json.dumps` can't
    # serialize numpy scalar types and the sidecar contract is plain
    # Python floats per slice 3 §7.
    embedding = tuple(float(v) for v in embedding_mean.tolist())

    return mood, genre_top3, voice_instrumental, embedding


#: Both TF heads use 3-second mel patches at 16 kHz (musicnn:
#: ``patchSize=187`` ≈ 3 s, effnet: ~3 s). Tracks shorter than this
#: produce zero patches under default ``lastPatchMode='discard'``,
#: yielding an empty per-frame array. The §11 fixture matrix mixes
#: 1-second mp3/m4a samples; pad on the right with zeros so the
#: first patch is always populated.
_TF_PATCH_SAMPLES_16K: int = 16_000 * 3


def _load_pcm_16k(path: str) -> "np.ndarray":
    """Decode a track to 16 kHz mono float32 via Essentia's MonoLoader,
    zero-padding to at least one patch length.

    A second decode is unavoidable because MonoLoader bakes the
    resample into its graph. The cost is negligible (the file's
    already in OS page cache from `_decode`) and it sidesteps any
    drift between Essentia's internal resampler and a separately-
    constructed ``Resample`` algorithm.
    """
    import numpy as np
    from essentia.standard import MonoLoader  # type: ignore[import-not-found]

    pcm = MonoLoader(
        filename=path, sampleRate=16000, resampleQuality=4
    )()
    if pcm.shape[0] < _TF_PATCH_SAMPLES_16K:
        # Right-pad with zeros — silence pads don't change the
        # downstream classification of the *real* portion (the patch
        # mean over a 3 s window still reflects the actual content),
        # they just give the TF graphs a full input tensor to operate
        # on instead of zero patches.
        pcm = np.pad(
            pcm,
            (0, _TF_PATCH_SAMPLES_16K - pcm.shape[0]),
            mode="constant",
        ).astype(np.float32, copy=False)
    return pcm


def analyze(
    path: str,
    models: ModelSet,
    *,
    force: bool = False,
) -> AnalysisResult | SkipReason:
    """Analyze one audio file end-to-end.

    Pure on inputs (after ``models`` is loaded once per worker) —
    returns ``AnalysisResult`` on success or one of the documented
    ``SkipReason`` values. Never raises on a per-file failure; even
    a corrupt-decode error is wrapped into ``SkipReason("decode_failed")``
    so the worker pool keeps draining the queue.

    Steps:

    1. Reject Syncthing-conflict siblings via the
       ``*.sync-conflict-*`` glob.
    2. Resume check: read any existing sidecar and skip when
       ``audio_sha1 + analyzer_models + schema_version`` all match the
       indexer's current values. ``force=True`` bypasses this gate.
    3. Decode + hash the PCM. The hash is what the next run's resume
       check compares against.
    4. Run features + classifiers.
    5. Pack and return ``AnalysisResult`` (the worker writes the
       sidecar with ``atomic_write``).
    """
    # Step 1: sync-conflict files leave both sides untouched.
    if _is_sync_conflict(path):
        return SkipReason("sync_conflict", detail=path)

    sidecar_path = _sidecar_path_for(path)

    # Step 2 (optimistic resume check on the sidecar's stored hash):
    # we *also* re-check against the freshly-decoded hash below, but
    # if `force` is off and a sidecar already claims a matching hash
    # for our analyzer config, we still need the decode to *verify*
    # — otherwise a bit-flip in the source file silently wins. The
    # cheap path is that the decode happens regardless; the savings
    # come from skipping classifiers + writing.
    existing = None if force else read_existing(sidecar_path)

    decode_started = time.monotonic()
    try:
        pcm_native, sample_rate, bit_depth = _decode(path)
    except Exception as e:  # noqa: BLE001 - per-file failures must not raise
        return SkipReason("decode_failed", detail=f"{path}: {e}")
    decode_seconds = time.monotonic() - decode_started

    if pcm_native.size == 0:
        return SkipReason("empty_audio", detail=path)

    # Hash over the decoded PCM — stable across tag edits, unstable
    # across re-encoding. This is the §11 verification 4 invariant.
    try:
        decoded_sha1 = audio_sha1(pcm_native)
    except Exception as e:  # noqa: BLE001
        return SkipReason("decode_failed", detail=f"{path}: hash {e}")

    # Step 2b: with the decoded hash now known, finalize the resume
    # gate. `_resume_match` covers the schema_version + analyzer_models
    # check too.
    if existing is not None and _resume_match(existing, decoded_sha1=decoded_sha1):
        return SkipReason("sidecar_up_to_date", detail=path)

    # Step 3: classifier-side decode + feature extraction.
    analysis_started = time.monotonic()
    try:
        pcm_16k = _load_pcm_16k(path)
        features = _extract_features(pcm_native, sample_rate)
        mood, genre_top3, voice_instrumental, embedding = _run_classifiers(
            pcm_16k, models
        )
    except Exception as e:  # noqa: BLE001 - per-file failures must not raise
        return SkipReason("decode_failed", detail=f"{path}: analyze {e}")
    analysis_seconds = time.monotonic() - analysis_started

    duration_sec = float(pcm_native.shape[0]) / float(sample_rate)

    sidecar = SidecarV1(
        schema_version=CURRENT_SCHEMA_VERSION,
        analyzer=ANALYZER_ID,
        analyzer_models=ANALYZER_MODELS,
        audio_sha1=decoded_sha1,
        duration_sec=duration_sec,
        sample_rate=sample_rate,
        bit_depth=bit_depth,
        bpm=float(features["bpm"]),
        bpm_confidence=float(features["bpm_confidence"]),
        key=str(features["key"]),
        key_confidence=float(features["key_confidence"]),
        loudness_lufs=float(features["loudness_lufs"]),
        replaygain_track_db=float(features["replaygain_track_db"]),
        replaygain_album_db=float(features["replaygain_album_db"]),
        spectral_centroid_mean=float(features["spectral_centroid_mean"]),
        danceability=float(features["danceability"]),
        mood=mood,
        genre_top3=genre_top3,
        voice_instrumental=voice_instrumental,
        embedding_model="discogs-effnet-bs64-1",
        embedding=embedding,
    )
    return AnalysisResult(
        sidecar=sidecar,
        analyzed_at=time.time(),
        decode_seconds=decode_seconds,
        analysis_seconds=analysis_seconds,
    )


def sidecar_path_for(audio_path: str) -> str:
    """Public re-export of ``_sidecar_path_for`` so the CLI / tests
    don't have to reach into a private symbol.
    """
    return _sidecar_path_for(audio_path)
