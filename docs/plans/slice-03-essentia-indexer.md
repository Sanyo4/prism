# Slice 3 — Essentia indexer (Linux-only Python CLI)

## 1. Context

Slice 3 builds `prism-indexer`, a Python 3.11+ command-line tool that
walks a music folder, decodes each audio file once, runs Essentia plus
two TensorFlow graphs (musicnn-msd-2 and discogs-effnet-bs64-1) to
produce BPM, key, loudness, mood probabilities, genre top-3, a 1280-d
embedding, and writes a `.sonic.json` sidecar atomically next to the
audio file. **This slice is Linux-only.** The indexer never runs on a
phone — it assumes an x86_64 Linux laptop with Essentia's Python
wheels available, refuses to execute elsewhere, and lets Syncthing
replicate the resulting sidecars to Android so the Flutter app reads
them as a passive consumer. Slice 3 lives in its own language tree
(`apps/indexer/`) and has zero dependency on slices 1 and 2; it can
ship in parallel on a separate branch. Its output format is locked by
`docs/spec.md` — this plan refines *how* to produce that JSON, not
what shape it takes.

## 2. Goals / Non-goals

**Goals**

- `apps/indexer/` Python package with CLI entry `prism-indexer`, invoked
  as `prism-indexer scan <path> [--workers N] [--force]`.
- **Linux x86_64 only.** The binary exits non-zero with a pointer to
  `docs/spec.md` when invoked on macOS, Windows, Android (Termux), or
  any non-`x86_64` Linux.
- Resumable scans: for each audio file, skip analysis when an existing
  `.sonic.json` sidecar has matching `audio_sha1`, `analyzer_models`,
  and `schema_version`.
- Lazy, SHA256-pinned model download to `~/.cache/prism/models/`. The
  pins live in `indexer/models.py` as literal hex strings and the
  indexer refuses to use a file whose on-disk digest does not match.
- Analysis pipeline: decode once via Essentia's `MonoLoader`, emit two
  streams — `16 kHz` mono for classifiers and native-rate mono for
  loudness / ReplayGain — then run musicnn-msd-2, discogs-effnet-bs64-1
  (embedding from the 1280-d penultimate activation), `RhythmExtractor2013`,
  `KeyExtractor`, `LoudnessEBUR128`, `Danceability`, `Centroid`, and
  pack into `SidecarV1`.
- Atomic sidecar writes: JSON is serialized to `<track>.sonic.json.tmp`
  in the same directory, `os.fsync`'d, then `os.rename`'d to the final
  name. No partial `.sonic.json` ever exists on disk.
- Process-based worker pool (`multiprocessing.Pool`) sized to
  `--workers` (default `max(1, cpu_count - 1)`). Each worker loads the
  two TF graphs once and reuses them across tracks.
- Sidecar JSON matches `docs/spec.md` byte-exact: same field names,
  same ordering (Python dict insertion order mirrors the spec), same
  units (LUFS, dB, Hz, seconds, BPM), same embedding dtype (list of
  `float`, no `numpy.float32` wrappers).

**Non-goals**

- **macOS, Windows, Android, BSD, iOS, non-x86_64 Linux.** macOS may
  work unofficially (Essentia has macOS wheels) but is documented
  unsupported — no CI, no triage, no mirror pinning.
- SQLite reads or writes — slice 4 owns the per-device cache.
- Any Flutter / Dart / Melos involvement. `apps/indexer/` has its own
  `pyproject.toml` and version contract.
- Tag editing. The indexer reads PCM; tag metadata is slice 1's domain.
- Artwork extraction. `cover.jpg` discovery lives in slice 2.
- Network calls beyond first-run model fetch. No MusicBrainz, CAA, or
  Last.fm traffic originates from the indexer.
- GPU inference. TF runs on CPU via the bundled Essentia backend.
- A daemon / watch mode. One-shot per invocation; Syncthing doesn't
  need a live analyzer and a daemon complicates the Linux-only story.
- Phone-side re-analysis. The phone stays read-only per
  `docs/plans/README.md` invariants.

## 3. Dependencies

Depends on: —
Unblocks: 4

## 4. Docs to refresh

Run each before writing any Python. Save a ≤5-line "API summary" note
per library in a scratch file so drift from training data is caught
before it hits the keyboard.

### Essentia (Python bindings)

- `WebFetch https://essentia.upf.edu/installing.html` — wheel vs conda
  vs source-build matrix on Linux; which distro versions ship the
  `essentia-tensorflow` wheel.
- `WebFetch https://essentia.upf.edu/python_reference.html` — current
  algorithm surface for `MonoLoader`, `RhythmExtractor2013`,
  `KeyExtractor`, `LoudnessEBUR128`, `Danceability`, `Centroid`.
- `WebFetch https://essentia.upf.edu/tutorial_tensorflow_auto-tagging_classification_embeddings.html`
  — `TensorflowPredictMusiCNN` and `TensorflowPredictEffnetDiscogs`
  invocation signatures and penultimate-layer access.

**API summary reminder:** on Linux x86_64 the path of least resistance
is `pip install essentia-tensorflow` (manylinux wheel bundles TF 2.x +
the graph runner). The plain `essentia` wheel lacks TF; classifiers
fail silently. Confirm which wheel name publishes the TF-enabled build
for the Python version chosen (3.11+). `MonoLoader(filename=...,
sampleRate=16000)` decodes to float32 mono — separately construct at
native rate (`sampleRate=0` is *not* accepted, pass the probed rate)
for loudness.

### musicnn-msd-2 model card

- `WebFetch https://essentia.upf.edu/models/` — master model index;
  find the exact `msd-musicnn-2.pb` (or current equivalent) release
  URL, SHA256, and input/output tensor names.
- `WebFetch https://essentia.upf.edu/models.html` — model card text:
  training corpus (MSD), output tag vocabulary, license.

**API summary reminder:** the MSD-musicnn head emits 50 top-level tags;
Prism keeps the five we call moods (`happy`, `sad`, `aggressive`,
`relaxed`, `party`) plus derived `danceability` (from a sibling MSD
model, not musicnn itself — confirm during refresh) and the top-3
genre projection mapped through `genre_discogs400` *or* the native MSD
genre vocabulary — the refresh confirms which head supplies `genre_top3`
in the sidecar.

### discogs-effnet-bs64-1 model card

- `WebFetch https://essentia.upf.edu/models/feature-extractors/discogs-effnet/`
  — the exact `discogs-effnet-bs64-1.pb` URL + SHA256 + input batch
  expectations (batch size 64, 128×96 mel patches).
- `WebFetch https://essentia.upf.edu/models.html` — card text for the
  effnet family; confirm the penultimate-layer name used to extract the
  1280-d embedding.

**API summary reminder:** the discogs-effnet classifier head gives 400
genre labels; Prism uses both (a) the head's argmax top-3 for
`genre_top3`, and (b) the penultimate 1280-d activation as
`embedding`. Essentia exposes penultimate activations via an optional
`output` parameter on `TensorflowPredictEffnetDiscogs` — the refresh
confirms the exact tensor name (often `PartitionedCall:1` or
`model/global_average_pooling2d/Mean:0`; memorized guesses will drift).

### `librosa`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "librosa"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "resample soxr_hq float32 load"`.

**API summary reminder:** used only if Essentia's `MonoLoader` at 16 kHz
drifts audibly from reference `soxr_hq`. Primary path stays
`MonoLoader(sampleRate=16000)`; fall back to `librosa.resample(...,
res_type='soxr_hq')` only if a test track's musicnn probabilities
differ by more than rounding error. Listed up front so the dep isn't
retrofitted mid-slice.

### `click`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "click"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "group command option argument path callback"`.

**API summary reminder:** `@click.group` for the top-level CLI,
`@click.command` for `scan`, `click.Path(exists=True, file_okay=False,
dir_okay=True, resolve_path=True)` for the folder argument. `--workers`
is an `int` with a default derived at runtime (not a module-level
import-time constant — that breaks process pools).

### Supporting stdlib

- `WebFetch https://docs.python.org/3/library/multiprocessing.html` —
  `Pool(initializer=..., initargs=...)` semantics; fork is the default
  start method on Linux (another reason macOS is unsupported: spawn
  there forces per-worker model re-import).
- `WebFetch https://docs.python.org/3/library/os.html#os.rename` —
  atomic-rename guarantees on ext4/btrfs (the `cactus` pattern).
  `hashlib` streaming API is stable and needs no refresh.

## 5. Architecture & data flow

### Sync model (the invariant this slice anchors)

```
    Linux laptop (indexer runs here)             Android phone (read-only)
    ┌────────────────────────────────┐           ┌────────────────────────────────┐
    │  prism-indexer scan ~/Music    │           │  Flutter app (slice 4+)        │
    │  ├── MonoLoader decode         │           │  ├── sidecar reader            │
    │  ├── Essentia + TF analysis    │           │  ├── SQLite + vec0 cache       │
    │  └── atomic write .sonic.json  │           │  └── browse / radio / LLM      │
    │          │                     │           │                                │
    │          ▼                     │           │          ▲                     │
    │   ~/Music/A/B/01 - Song.flac   │           │   /sdcard/Music/A/B/01 - ...   │
    │   ~/Music/A/B/01 - Song.sonic. │           │   ~/... /01 - Song.sonic.json  │
    │                         json   │           │                                │
    └──────────────┬─────────────────┘           └──────────────┬─────────────────┘
                   │                                            │
                   │       Syncthing folder (bi-directional)    │
                   │       replicates .flac + .sonic.json       │
                   │       (sidecars are tiny; bandwidth-free)  │
                   └──────────────────────┬─────────────────────┘
                                          ▼
                               ┌──────────────────────────┐
                               │  source of truth on disk │
                               │  audio + sidecar side by │
                               │  side, keyed by filename │
                               └──────────────────────────┘
```

**Invariant restated.** Only the Linux box writes sidecars. Android
never invokes analysis. The sync channel is Syncthing, which the app
never programmatically touches — it sees the sidecar file appear (or
change mtime) and re-scans accordingly in slice 4. This diagram is
the anchor figure for the project; any later slice that proposes
"analyze on the phone" or "push analysis over the network" is in
conflict with it and must edit `docs/spec.md` first.

### Internal pipeline (per track, inside one worker process)

```
 ┌───────────────┐     ┌──────────────────┐     ┌──────────────────────┐
 │ source file   │ ──► │  probe duration  │ ──► │  MonoLoader @ native │
 │ *.flac/mp3/.. │     │  sample_rate     │     │  rate  → pcm_native  │
 └───────────────┘     │  bit_depth       │     └───────────┬──────────┘
                       └──────────────────┘                 │
                                 │                          │
                                 ▼                          ▼
                       ┌──────────────────┐     ┌──────────────────────┐
                       │  MonoLoader 16k  │     │ LoudnessEBUR128      │
                       │  → pcm_16k       │     │  → loudness_lufs,    │
                       └──────┬───────────┘     │    replaygain_track/ │
                              │                 │    album_db          │
                              │                 └──────────────────────┘
             ┌────────────────┼────────────────┐
             ▼                ▼                ▼
    ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────────┐
    │ TF musicnn-msd-2 │ │ TF discogs-effnet│ │ RhythmExtractor2013  │
    │ → mood probs,    │ │ → genre_top3,    │ │ KeyExtractor,        │
    │   voice_instr.   │ │   embedding[1280]│ │ Danceability,        │
    └────────┬─────────┘ └────────┬─────────┘ │ SpectralCentroid     │
             │                    │           └────────────┬─────────┘
             └───────┬────────────┴────────────────────────┘
                     ▼
           ┌────────────────────────────┐
           │  SidecarV1 dataclass       │
           │  → JSON (spec field order) │
           │  → .sonic.json.tmp         │
           │  → fsync + os.rename       │
           └────────────────────────────┘
```

A worker decodes each file exactly once into `pcm_native` (float32
mono), then resamples *inside Essentia's graph* to produce `pcm_16k`
for classifiers — memory stays flat, no double-decode. `audio_sha1`
is a streaming SHA1 over `pcm_native.tobytes()`: stable across tag
edits, unstable across re-encoding (the intended semantics). The
parent process owns the file queue and progress bar; workers are
pure functions of `(path, model_set) → SidecarV1 | SkipReason`.

## 6. File layout (new files only)

```
/apps/indexer/pyproject.toml                  # project metadata + deps + CLI entry point
/apps/indexer/README.md                       # two lines: what runs, where models land
/apps/indexer/indexer/__init__.py             # exports SidecarV1, CURRENT_SCHEMA_VERSION
/apps/indexer/indexer/__main__.py             # `python -m indexer ...` delegates to cli.main
/apps/indexer/indexer/cli.py                  # click group + `scan` command + platform guard
/apps/indexer/indexer/pipeline.py             # per-track analyze(path, models) → AnalysisResult
/apps/indexer/indexer/models.py               # ModelSet, URLs, SHA256 pins, lazy download/verify
/apps/indexer/indexer/sidecar.py              # SidecarV1 dataclass, to_json, atomic_write, read
/apps/indexer/indexer/hashing.py              # streaming audio_sha1 over decoded PCM
/apps/indexer/indexer/platform_guard.py       # refuse to run on non-Linux / non-x86_64
/apps/indexer/indexer/progress.py             # tqdm wrapper; silent in --workers=1 unit tests
/apps/indexer/tests/test_sidecar_shape.py     # JSON shape matches docs/spec.md byte-exact
/apps/indexer/tests/test_resume.py            # skip/force semantics on a fixture tree
/apps/indexer/tests/test_platform_guard.py    # monkeypatched darwin/win32 → SystemExit
/apps/indexer/tests/fixtures/silent_1s.flac   # 16-bit 44.1 kHz silence, 1 second, ~4 kB
/apps/indexer/tests/fixtures/sine_3s.flac     # 440 Hz sine, stereo → mono check
```

## 7. Interfaces & key types

```python
# indexer/sidecar.py
from dataclasses import dataclass, field
from typing import Literal

CURRENT_SCHEMA_VERSION: int = 1
ANALYZER_ID: str = "essentia-2.1-beta6-dev"   # matches Essentia wheel __version__
ANALYZER_MODELS: tuple[str, ...] = ("musicnn-msd-2", "discogs-effnet-bs64-1")

@dataclass(frozen=True, slots=True)
class MoodVector:
    happy: float
    sad: float
    aggressive: float
    relaxed: float
    party: float

@dataclass(frozen=True, slots=True)
class SidecarV1:
    schema_version: int                              # 1
    analyzer: str                                    # ANALYZER_ID
    analyzer_models: tuple[str, ...]                 # ANALYZER_MODELS
    audio_sha1: str                                  # hex, lowercase, 40 chars
    duration_sec: float
    sample_rate: int
    bit_depth: int | None                            # None for lossy sources
    bpm: float
    bpm_confidence: float
    key: str                                         # e.g. "Fm", "C#", "Bbm"
    key_confidence: float
    loudness_lufs: float
    replaygain_track_db: float
    replaygain_album_db: float                       # == track RG when album unknown
    spectral_centroid_mean: float                    # Hz
    danceability: float                              # 0..1
    mood: MoodVector
    genre_top3: tuple[tuple[str, float], ...]        # exactly 3 entries
    voice_instrumental: float                        # 1.0 = fully instrumental
    embedding_model: Literal["discogs-effnet-bs64-1"]
    embedding: tuple[float, ...]                     # length 1280

    def to_json_bytes(self) -> bytes:
        """Serialize in spec field order, no trailing newline."""
```

Field order in `to_json_bytes` is hand-specified — not alphabetic, not
`dataclasses.asdict` default — because `docs/spec.md` shows a specific
order and readers rely on it when eyeballing diffs. `MoodVector`
stays nested in JSON; slice 4 flattens it into SQLite `mood_*` columns.

```python
# indexer/pipeline.py
@dataclass(frozen=True, slots=True)
class AnalysisResult:
    sidecar: SidecarV1                               # ready to serialize
    analyzed_at: float                               # wall-clock epoch seconds
    decode_seconds: float
    analysis_seconds: float

@dataclass(frozen=True, slots=True)
class SkipReason:
    reason: Literal[
        "sidecar_up_to_date",   # audio_sha1 + analyzer_models + schema_version match
        "unsupported_extension",
        "decode_failed",
        "empty_audio",
        "sync_conflict",        # filename matches .sync-conflict-* pattern
    ]
    detail: str                                      # human-readable, logged once

def analyze(path: str, models: "ModelSet", *, force: bool) -> AnalysisResult | SkipReason:
    """Pure per-file function. Safe to call in a worker. Never raises
    on per-file errors — all failures become SkipReason."""
```

```python
# indexer/models.py
@dataclass(frozen=True, slots=True)
class ModelPin:
    name: str                    # e.g. "discogs-effnet-bs64-1"
    url: str                     # primary HTTPS URL on essentia.upf.edu
    mirror_urls: tuple[str, ...] # fallbacks (see §10 risk 2)
    sha256: str                  # lowercase hex, 64 chars
    relpath: str                 # relative to ~/.cache/prism/models/

@dataclass(slots=True)
class ModelSet:
    musicnn: object              # TensorflowPredictMusiCNN instance
    effnet: object               # TensorflowPredictEffnetDiscogs instance
    effnet_embedding_output: str # tensor name for 1280-d penultimate

def ensure_models(cache_dir: str) -> ModelSet:
    """Download-if-missing, verify SHA256, load into memory. Called once
    per worker via Pool(initializer=...). Raises on hash mismatch."""
```

`ModelSet` is intentionally untyped (`object`) on the two Essentia
instances — Essentia's Python API is dynamic and a strict annotation
would drift against new wheels. The dataclass stays agnostic; the
refresh confirms exact class names.

## 8. Implementation steps

Ordered. Each step names its files and a pass criterion. Stop at the
criterion before the next step.

1. **Platform guard.** `indexer/platform_guard.py`: assert
   `sys.platform == "linux"` and `platform.machine() == "x86_64"`.
   On mismatch raise `SystemExit(2)` with a message naming the
   detected platform and pointing at `docs/spec.md` §Architecture.
   Hook from `cli.main` before click dispatches.
   **Pass:** `test_platform_guard.py` monkeypatches `sys.platform` to
   `"darwin"`, asserts exit code `2` and message containing `Linux`.

2. **CLI skeleton.** `indexer/cli.py`: `click.group()` + `scan`
   subcommand with `click.Path(exists=True, dir_okay=True,
   file_okay=False, resolve_path=True)`, `--workers int`, `--force
   is_flag`. `pyproject.toml` declares console script
   `prism-indexer = "indexer.cli:main"`.
   **Pass:** `pip install -e .` then `prism-indexer --help` prints
   the subcommand surface.

3. **Sidecar dataclasses + serializer.** `indexer/sidecar.py`:
   `SidecarV1`, `MoodVector`, `to_json_bytes` emitting fields in
   exact `docs/spec.md` order, UTF-8, `separators=(", ", ": ")`, no
   trailing newline. `read_existing(path) -> SidecarV1 | None`
   tolerates unknown keys, returns `None` on malformed JSON.
   **Pass:** `test_sidecar_shape.py` builds a `SidecarV1` from the
   spec's example block and asserts byte-for-byte field ordering.

4. **Atomic write pattern.** Add `atomic_write(path, payload)` opening
   `path + ".tmp"` in the *same directory*, `f.flush()`, `os.fsync`,
   close, `os.rename(tmp, path)`. No cross-device fallback — if the
   target is on a different FS, fail loudly (breaks Syncthing co-
   location).
   **Pass:** a test kills the process between write and rename (via
   `os._exit` in a subprocess) and asserts the final `.sonic.json` is
   either absent or byte-identical to the payload — never partial.

5. **Streaming audio hash.** `indexer/hashing.py`: take a `float32`
   mono PCM `numpy.ndarray`, feed 1 MiB slices of `.tobytes()` into
   `hashlib.sha1()`, return hex digest. Runs on the same decoded array
   the graphs consume — no double read.
   **Pass:** 1 s silence yields the deterministic digest committed in
   the test; flipping one sample yields a different digest.

6. **Model pins + downloader.** `indexer/models.py` declares
   `MUSICNN_PIN` and `EFFNET_PIN` as `ModelPin` literals with SHA256
   committed in source. `ensure_models(cache_dir)`: for each pin, try
   `pin.url` then `pin.mirror_urls` in sequence (HTTPS only,
   `User-Agent: prism-indexer/<version>`), verify SHA256, load via
   Essentia's TF predict constructors. On hash mismatch delete the
   file and raise. No auto-retry of the same URL.
   **Pass:** `cache_dir` seeded with a corrupted `.pb` → the function
   deletes, re-fetches, verifies, returns a `ModelSet`. A mocked
   fetcher proves the primary URL is tried before mirrors.

7. **Decode + probe.** `pipeline._decode(path) -> (pcm_native,
   sample_rate, bit_depth)`. Uses `essentia.standard.AudioLoader` for
   raw PCM + stream info; mixes to mono by channel mean. `bit_depth`
   is `None` for lossy codecs per spec semantics.
   **Pass:** `sine_3s.flac` decodes to ~132 300 samples at 44 100 Hz,
   `bit_depth == 16`.

8. **Essentia feature extraction.** `_extract_features(pcm_native,
   sample_rate) -> dict`. `RhythmExtractor2013` (method=`multifeature`)
   → `(bpm, bpm_confidence)`. `KeyExtractor` → `(key, key_confidence)`
   formatted as `"Fm"` / `"C#"` / `"Bbm"` per spec. `LoudnessEBUR128`
   (on stereo-duplicated mono) → `loudness_lufs`; derive
   `replaygain_track_db = -18.0 - loudness_lufs`; album RG equals track
   RG here and is re-grouped in slice 4. `Centroid` + `SpectralPeaks`
   over windowed frames → `spectral_centroid_mean` (Hz arithmetic
   mean). `Danceability` → divide Essentia's 0–3 output by 10 to
   normalize into 0–1 per spec.
   **Pass:** `sine_3s.flac` yields finite values and a key of `"A"`
   (or enharmonic).

9. **TF classifier + embedding.** `_run_classifiers(pcm_16k, models)`
   calls `models.musicnn(pcm_16k)` and `models.effnet(pcm_16k)`. Picks
   the five mood tags from musicnn-MSD's output vocabulary and derives
   `voice_instrumental` from the same head's `instrumental` tag
   (refresh confirms exact name). Takes effnet's classifier head
   softmax top-3 for `genre_top3`. Reads the 1280-d penultimate
   activation via Essentia's `output` constructor param
   (`models.effnet_embedding_output`), time-averages, casts to
   `list[float]` (Python floats, not `numpy.float32`).
   **Pass:** `sine_3s.flac` → length-1280 embedding, `json.dumps`
   succeeds without a custom encoder.

10. **`analyze()` composition + resume check.** `analyze(path, models,
    *, force)`: (a) sibling matches `*.sync-conflict-*.sonic.json` →
    `SkipReason("sync_conflict")`; (b) compute expected sidecar path;
    (c) unless `force`, read existing sidecar — if `audio_sha1`,
    `analyzer_models`, `schema_version` all match, return
    `SkipReason("sidecar_up_to_date")`; (d) decode, hash, extract,
    classify, build `SidecarV1`, return `AnalysisResult`.
    **Pass:** `test_resume.py` runs twice — the second call returns
    `SkipReason("sidecar_up_to_date")` and the mocked `atomic_write`
    is never invoked on the second pass.

11. **Worker pool + CLI glue.** `scan` walks via `os.walk
    (followlinks=False)`, filters by extension, creates
    `multiprocessing.Pool(processes=workers, initializer=_init_worker,
    initargs=(cache_dir,))` where `_init_worker` sets a module-level
    `MODELS = ensure_models(cache_dir)`. Submits via
    `pool.imap_unordered(_worker, paths)`. `_worker(path)` runs
    `analyze` and calls `atomic_write` on success. `tqdm` for progress.
    **Pass:** `prism-indexer scan tests/fixtures/ --workers 2` yields
    two sidecars and a skip-reason summary.

12. **Packaging + entry point.** Final `pyproject.toml`: name
    `prism-indexer`, version `0.1.0`, Python `>=3.11`; deps
    `essentia-tensorflow`, `click`, `tqdm`, `numpy`; dev dep `pytest`.
    `indexer/__main__.py` re-exports `cli.main` so `python -m indexer`
    works when the shim isn't on PATH.
    **Pass:** `pip install -e .` resolves in a clean venv;
    `prism-indexer --version` prints `0.1.0`.

13. **Run §11.** **Pass:** every numbered verification item is green.

## 9. Alternatives considered

**Dart-native analysis (skip Python entirely).** Removes a language
boundary. Rejected because no Dart package binds Essentia and no
Dart package ships music-ML TF graphs; porting musicnn + effnet-discogs
to `tflite_flutter` or ONNX is a full slice of its own with ongoing
model-surgery at every upstream release. Python + Essentia gives us
four maintained extractors for free. Reconsider only if a
`just_essentia` Dart binding appears with upstream's blessing *and*
both heads are republished as `.tflite` with verified parity.

**Run analysis on the phone too.** Symmetric, appealing on paper.
Rejected because (a) Essentia's TF graphs drain ~8% Pixel 9 Pro Fold
battery per 20 tracks; (b) Syncthing already fans sidecars out for
free; (c) two writers reintroduce the sync-conflict class the single-
writer invariant exists to kill. Reconsider only if a music-ML NPU
ships at <50 mW sustained *and* the user adopts a solo-phone workflow.

**CLAP embeddings instead of musicnn + effnet-discogs.** CLAP (LAION)
gives 512-d text-aligned embeddings — slice 6's LLM could kNN against
a raw text prompt, skipping intent-JSON. Rejected because CLAP weights
are ~600 MB vs effnet's ~80 MB, CLAP is ~5× slower per track, CLAP has
no genre head (we'd still run effnet for `genre_top3`), and slice 6's
intent-JSON flow is fine against effnet's space per spec. Reconsider
after slice 6 by adding CLAP as a *second* embedding (switch via
`embedding_model`), never as a replacement.

## 10. Edge cases & known risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Essentia wheel absent for the user's distro / Python. | `essentia-tensorflow` publishes `manylinux2014_x86_64` wheels for CPython 3.9–3.12. If the user is on 3.13 the wheel fails to resolve — the README names 3.11/3.12 as supported; 3.13 is deferred until the wheel ships. Conda fallback (`conda install -c mtg essentia`) is documented but not the primary install path. |
| 2 | Model URL 404 (release rotation on essentia.upf.edu). | Each `ModelPin` carries `mirror_urls` — the refresh step records at least one non-UPF mirror (HuggingFace Hub is the obvious second host). Hash pinning means a rotated URL with altered weights fails closed: the tool refuses to use a file that doesn't match the committed SHA256. Bumping the pin is a deliberate source-tree change, not a silent upgrade. |
| 3 | Corrupt audio decode (unreadable or mid-file error). | `essentia.standard.AudioLoader` raises `RuntimeError` → `SkipReason("decode_failed", detail=<message>)`. No sidecar written, walk continues, final summary lists failed paths. |
| 4 | Tracks without ReplayGain tags. | The indexer doesn't read tag RG at all — it *computes* RG from EBU R128 loudness. Slice 1's playback path prefers tag RG when present, falls back to sidecar RG (via slice 4's ingest) when tag RG is missing. Two independent sources by design. |
| 5 | Symlinked audio files. | `os.walk(followlinks=False)` by default; symlinked directories are not traversed. Symlinked files *to* an audio file are followed (single-file symlinks resolve transparently via `open`). Document in the README: the recommended layout is one real library root, no symlink fan-out; behavior on recursive symlink loops is "we don't". |
| 6 | Syncthing conflict sidecars (`*.sync-conflict-*.sonic.json`). | The walker ignores any path matching the glob `*.sync-conflict-*`. A conflict sidecar for an audio file is treated as inert — neither read nor overwritten — so Syncthing's own conflict-resolution flow stays the user's responsibility. Logged at INFO level per file. |
| 7 | Schema version bump strategy. | `CURRENT_SCHEMA_VERSION` is a single `int` in `indexer/__init__.py`. Bumping it in a future slice (e.g. to add a `beat_positions` array) causes every existing sidecar to be re-analyzed on next scan because the resume check fails the `schema_version` comparison. That is the intended, loud, one-time cost of a breaking field change. Additive changes (new optional fields) do not require a bump — readers ignore unknowns per `docs/spec.md`. |
| 8 | Partial write due to power loss / OOM. | `atomic_write` in §8 step 4 is the full mitigation: on Linux ext4 / btrfs, `rename(2)` is atomic over a single filesystem. The `.tmp` file may survive a crash and will be overwritten on the next scan. |
| 9 | Two indexer processes racing on the same folder. | Unscoped — we assume a single `prism-indexer` invocation at a time on one machine. A cooperative lock file (`~/.cache/prism/indexer.lock`) is a two-line follow-up if needed, but Syncthing users run a single desktop; no real multi-writer scenario exists given invariant §2. |
| 10 | Long paths / non-UTF-8 filenames. | All filesystem I/O goes through `pathlib.Path` / `os` with `bytes` tolerance; the sidecar JSON is UTF-8 with `ensure_ascii=False`. Filenames themselves are not stored in the sidecar (spec does not include path) so encoding drift in filenames does not corrupt JSON payloads. |

## 11. Verification

Run in order. Items 1–6 are the explicit slice-3 acceptance criteria
listed in `docs/spec.md`'s verification table.

1. Seed a fixture folder with **20 tracks** of mixed extensions
   (`.flac`, `.mp3`, `.m4a`). Run `prism-indexer scan <fixture>`.
   **Expect** exactly 20 `.sonic.json` files, none zero-byte, each
   valid JSON with `schema_version == 1`.
2. Re-run with **no changes**. **Expect** zero re-analyses — all 20
   skip as `sidecar_up_to_date`. Wall clock under 2 seconds on the
   reference laptop (fast path is JSON read + PCM-hash compare).
3. `touch <fixture>/one-track.flac` (content unchanged). Re-run.
   **Expect** 20 skips — mtime alone does not invalidate.
4. `ffmpeg -i <fixture>/one-track.flac -metadata title="X" -c copy
   <out>/one-track.flac` (re-mux, tags edited, PCM intact). Re-run.
   **Expect** 20 skips — the key property PCM-hashing buys over file-
   byte hashing.
5. Replace `<fixture>/one-track.flac` with a genuinely different
   recording. Re-run. **Expect** exactly **one re-analysis** and 19
   skips; the sidecar overwrites atomically.
6. `prism-indexer scan <fixture> --force`. **Expect all 20**
   re-analyzed regardless of sidecar state.
7. **Platform refusal.** Run the test suite with `sys.platform`
   monkeypatched to `"darwin"`; process exits `2`, stderr contains
   `Linux`. Running on real macOS is not a CI step.
8. **Model download.** Delete `~/.cache/prism/models/`; first run
   downloads both `.pb` files and verifies SHA256. Corrupt one byte;
   next run deletes and re-fetches.
9. **Sync-conflict sidecar left alone.** Create
   `one-track.sync-conflict-20240101-ABC.sonic.json`; the scanner
   leaves it untouched and writes the real sidecar as normal.

## 12. Definition of done

- [ ] `apps/indexer/pyproject.toml`, `indexer/__main__.py`,
  `indexer/cli.py`, `indexer/pipeline.py`, `indexer/models.py`,
  `indexer/sidecar.py`, `indexer/hashing.py`,
  `indexer/platform_guard.py`, `indexer/progress.py` all exist and
  `pip install -e apps/indexer/` resolves in a clean Python 3.11 venv.
- [ ] `prism-indexer --help` and `prism-indexer scan --help` print
  the documented flag surface (`--workers`, `--force`).
- [ ] Invoking the CLI on non-Linux (monkeypatched `sys.platform`) or
  non-`x86_64` exits with code `2` and an error mentioning Linux and
  `docs/spec.md`.
- [ ] `indexer/models.py` contains literal SHA256 pins for
  `musicnn-msd-2` and `discogs-effnet-bs64-1`. The tool refuses to
  load a model whose on-disk digest disagrees.
- [ ] `SidecarV1.to_json_bytes` round-trips against the example in
  `docs/spec.md` field-for-field in the correct order (asserted in
  `test_sidecar_shape.py`).
- [ ] `atomic_write` uses `.tmp` + `os.rename` within the same
  directory; a crash mid-write leaves either no file or a valid file,
  never a partial one (asserted in the kill-mid-write test).
- [ ] Running on the 20-track fixture yields 20 sidecars on first
  run and zero re-analyses on identical second run (§11 items 1–2).
- [ ] `--force` re-analyzes all 20 (§11 item 6).
- [ ] Re-muxing a file with identical PCM does **not** trigger
  re-analysis (§11 item 4) — this is the guarantee that makes
  PCM-hashing the right call over file-byte hashing.
- [ ] Sync-conflict sidecars are skipped, not overwritten (§11 item 9).
- [ ] No deferred-work sentinels remain — every unfinished item is
  scoped to a later slice and linked here by number.
- [ ] The §4 "Docs to refresh" commands were executed at session
  start and "API summary" notes written before any Python file was
  touched.
