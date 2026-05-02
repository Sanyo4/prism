"""Lazy, SHA256-pinned model fetcher + ``ModelSet`` runtime container.

This module is the single place where Essentia model identity lives:
URLs, hash pins, on-disk relpaths, and the runtime tensor names the
analysis pipeline reads. Pinning by SHA256 is the load-bearing
security control — a rotated upstream URL with altered weights fails
closed (the indexer refuses to use a mismatched file) instead of
silently changing analysis output across runs.

Phase A note: this module **does not import Essentia or TensorFlow**
at module import time. ``ensure_models()`` defers that import to its
body so the scaffold is fully unit-testable in environments without
the heavy wheels installed. Phase B will add a pipeline-level
``analyze()`` that calls ``ensure_models`` once per worker.

**Plan/spec deviation note** — slice 3 §7 calls the musicnn model
``musicnn-msd-2``; upstream publishes only ``msd-musicnn-1``. We pin
the upstream-actual filename. If a ``-2`` ever ships, bumping the pin
is a deliberate source change with a new SHA256.
"""

from __future__ import annotations

import hashlib
import os
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

#: Default cache directory under the user's home. Slice 3 §1 specifies
#: this exact path; the Linux-only invariant means we don't need to
#: branch on platformdirs.
DEFAULT_CACHE_DIR: str = os.path.expanduser("~/.cache/prism/models")

#: Stream size for the SHA256 verifier and the URL downloader. 1 MiB
#: matches the streaming-hash chunk in ``hashing.py`` so the same
#: cache-line behavior applies; small enough to keep peak memory low,
#: big enough to keep call overhead negligible for 80 MB files.
_DOWNLOAD_CHUNK_BYTES: int = 1 * 1024 * 1024

#: HTTP User-Agent the indexer sends on model fetches. Per Essentia's
#: hosting being polite-firewalled (no published rate limit but bots
#: get throttled), identifying ourselves means a future trace lands on
#: ``prism-indexer/<version>`` not a generic Python urllib.
_USER_AGENT_FMT: str = "prism-indexer/{version}"


@dataclass(frozen=True, slots=True)
class ModelPin:
    """One model file's identity. Hash pin is the load-bearing field;
    URL is replaceable, hash is not.
    """

    name: str
    """Stable identifier used in the sidecar's ``analyzer_models``."""

    url: str
    """Primary HTTPS URL on essentia.upf.edu."""

    mirror_urls: tuple[str, ...] = field(default_factory=tuple)
    """Optional mirrors tried in order on primary failure. Empty by
    default — slice 3 §10 risk 2 calls for at least one mirror per
    pin once the doc-refresh confirms a HuggingFace alternative.
    Phase A leaves them empty; phase B can fill in."""

    sha256: str = ""
    """Lowercase 64-char hex digest of the model file's bytes. The
    indexer refuses to use a file whose on-disk digest does not match.
    Empty string in Phase A scaffolding will fail the verification
    step — call sites must populate before ``ensure_models`` runs."""

    relpath: str = ""
    """Filename under [DEFAULT_CACHE_DIR]. Filename, not absolute path
    — the cache_dir argument to ``ensure_models`` is the join base."""


# --- Pinned model identities ------------------------------------------------
#
# These pins reference the *upstream-actual* filenames published at
# https://essentia.upf.edu/models/. The SHA256 placeholders below are
# empty strings in Phase A (scaffolding). Phase B will populate them
# from the actual files after first download — the slice plan §10
# risk 2 anticipates this: "Bumping the pin is a deliberate source-
# tree change, not a silent upgrade."
#
# Model filenames + URLs verified against essentia.upf.edu/models.html
# at slice-3 doc-refresh time.

MUSICNN_PIN: ModelPin = ModelPin(
    name="msd-musicnn-1",
    url=(
        "https://essentia.upf.edu/models/feature-extractors/musicnn/"
        "msd-musicnn-1.pb"
    ),
    mirror_urls=(),
    # Computed via `sha256sum msd-musicnn-1.pb` after two independent
    # downloads from essentia.upf.edu (Phase B verification: digests
    # matched on both pulls). The hash is the load-bearing security
    # control — a future upstream rotation that changes the weights
    # makes the indexer fail closed; bumping the pin is a deliberate
    # source change.
    sha256="cdea0722bcee7f731286843f2233e3aa69887bb5c3e2dce011eff55f38d04f3e",
    relpath="msd-musicnn-1.pb",
)

EFFNET_PIN: ModelPin = ModelPin(
    name="discogs-effnet-bs64-1",
    url=(
        "https://essentia.upf.edu/models/feature-extractors/discogs-effnet/"
        "discogs-effnet-bs64-1.pb"
    ),
    mirror_urls=(),
    sha256="3ed9af50d5367c0b9c795b294b00e7599e4943244f4cbd376869f3bfc87721b1",
    relpath="discogs-effnet-bs64-1.pb",
)

#: 400-class genre vocabulary for the discogs-effnet head, fetched
#: alongside the graph file at first run. The JSON sits next to the
#: ``.pb`` in upstream's release; we hash-pin it so a relabel upstream
#: fails closed the same way a graph rotation would.
EFFNET_LABELS_PIN: ModelPin = ModelPin(
    name="discogs-effnet-bs64-1-labels",
    url=(
        "https://essentia.upf.edu/models/feature-extractors/discogs-effnet/"
        "discogs-effnet-bs64-1.json"
    ),
    mirror_urls=(),
    # SHA256 of the upstream JSON metadata file (contains the 400-class
    # vocabulary the indexer reads for `genre_top3`). Verified
    # reproducible across two downloads.
    sha256="a35003202384735c33154e20264267f9941705218a7b93202b655a1d408d4ff6",
    relpath="discogs-effnet-bs64-1.json",
)

#: 50-class MSD vocabulary for the musicnn head — tag names map to
#: ``mood`` and ``voice_instrumental`` fields in the sidecar.
MUSICNN_LABELS_PIN: ModelPin = ModelPin(
    name="msd-musicnn-1-labels",
    url=(
        "https://essentia.upf.edu/models/feature-extractors/musicnn/"
        "msd-musicnn-1.json"
    ),
    mirror_urls=(),
    sha256="8e6b3b509f0610c0e65dce467fd459d6777509388eaddb13ed138d8ac1341ffe",
    relpath="msd-musicnn-1.json",
)


@dataclass(slots=True)
class ModelSet:
    """Runtime container handed to a worker after ``ensure_models``.

    Essentia instances are typed as ``object`` because the
    Essentia Python API is dynamic and a strict annotation would drift
    against new wheels. ``ensure_models`` populates these via
    ``TensorflowPredictMusiCNN`` and ``TensorflowPredictEffnetDiscogs``.

    Three TF instances are loaded per worker (one fork in Phase B's
    ``multiprocessing.Pool``):

    - ``musicnn`` — MSD-musicnn classifier head (50 tags).
    - ``effnet_predictions`` — discogs-effnet 400-class genre head
      via ``output='PartitionedCall:0'``.
    - ``effnet_embedding`` — discogs-effnet 1280-d penultimate
      activation via ``output='PartitionedCall:1'``.

    The two effnet instances must be separate because the Essentia
    algorithm caches the ``output`` tensor name internally; trying to
    swap it after construction is undefined behavior.
    """

    musicnn: object | None = None
    effnet_predictions: object | None = None
    effnet_embedding: object | None = None
    musicnn_classes: tuple[str, ...] = ()
    """50-class MSD vocabulary, in graph index order (idx i in this
    tuple corresponds to column i in the musicnn output matrix)."""
    effnet_classes: tuple[str, ...] = ()
    """400-class discogs vocabulary, in graph index order."""
    effnet_embedding_output: str = "PartitionedCall:1"
    """Tensor name for the 1280-d penultimate activation. Confirmed
    via the discogs-effnet-bs64-1.json schema at Phase B doc-refresh
    (output_purpose='embeddings'). A future upstream change would
    require an update here — bump along with the model SHA256 pin."""
    effnet_predictions_output: str = "PartitionedCall:0"
    """Tensor name for the 400-class softmax/sigmoid head. Confirmed
    via the same JSON schema (output_purpose='predictions')."""


# --- Verification + download primitives -------------------------------------


def sha256_of_file(path: str | os.PathLike[str]) -> str:
    """Streaming SHA256 of an on-disk file. Returns lowercase 64-char hex."""
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(_DOWNLOAD_CHUNK_BYTES)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _download_to(url: str, dest: str | os.PathLike[str], *, version: str) -> None:
    """Stream [url] → [dest], identifying ourselves with a versioned
    User-Agent. Raises on HTTP error.

    We download to ``<dest>.partial`` first and rename on completion,
    so a network drop mid-fetch can't leave a half-file masquerading
    as a complete model. The rename pattern mirrors ``atomic_write``.
    """
    dest_path = Path(os.fspath(dest))
    partial = dest_path.with_name(dest_path.name + ".partial")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": _USER_AGENT_FMT.format(version=version)},
    )
    with urllib.request.urlopen(request) as response, open(partial, "wb") as f:
        while True:
            chunk = response.read(_DOWNLOAD_CHUNK_BYTES)
            if not chunk:
                break
            f.write(chunk)
        f.flush()
        os.fsync(f.fileno())
    os.rename(partial, dest_path)


def fetch_pinned(
    pin: ModelPin,
    cache_dir: str | os.PathLike[str],
    *,
    version: str,
    fetcher: Callable[[str, str], None] | None = None,
) -> str:
    """Ensure [pin] is present and hash-correct under [cache_dir].

    Returns the absolute on-disk path. Raises :py:class:`ValueError`
    on hash mismatch (after deleting the bad file). Raises whatever
    the fetcher raises on network errors.

    [fetcher] is injectable for tests; defaults to a streaming HTTPS
    GET. Production callers leave it None.

    Behavior:
      1. If the file exists *and* its SHA256 matches ``pin.sha256``,
         return its path. (Cheap re-run path.)
      2. If the file exists but the digest mismatches, delete it.
      3. Try ``pin.url``, then each ``pin.mirror_urls`` in sequence.
         Each attempt downloads to a `.partial` file and renames on
         success. After each attempt, verify the SHA256.
      4. If no URL produces a matching file, raise ``ValueError``.
    """
    cache_path = Path(os.fspath(cache_dir))
    cache_path.mkdir(parents=True, exist_ok=True)
    target = cache_path / pin.relpath

    if pin.sha256 == "":
        # Phase A scaffolding can't verify because the pin is empty.
        # Make this loud — Phase B has to populate the pin before
        # `ensure_models` is wired into the worker initializer.
        raise ValueError(
            f"ModelPin {pin.name!r} has no SHA256 set — refusing to fetch. "
            "Phase B populates pins before first run."
        )

    # 1. Cache hit?
    if target.exists():
        if sha256_of_file(target) == pin.sha256:
            return str(target)
        # Mismatch → drop and refetch.
        target.unlink()

    # 2. Try primary then mirrors.
    actual_fetcher = fetcher or (
        lambda url, dest: _download_to(url, dest, version=version)
    )
    last_error: Exception | None = None
    for url in (pin.url, *pin.mirror_urls):
        try:
            actual_fetcher(url, str(target))
        except Exception as e:  # noqa: BLE001 - mirror fallback policy
            last_error = e
            continue
        if sha256_of_file(target) == pin.sha256:
            return str(target)
        # Bad digest — wipe and try next URL.
        target.unlink(missing_ok=True)
        last_error = ValueError(
            f"hash mismatch for {pin.name} fetched from {url}"
        )

    raise ValueError(
        f"failed to fetch a verified {pin.name} from any mirror"
    ) from last_error


def _load_labels(json_path: str) -> tuple[str, ...]:
    """Read the upstream model-card JSON and return its ``classes``
    list as an immutable tuple. The vocabulary order is contractual:
    column ``i`` of the model output corresponds to ``classes[i]``.
    """
    import json as _json

    with open(json_path, "rb") as f:
        meta = _json.load(f)
    classes = meta.get("classes")
    if not isinstance(classes, list) or not classes:
        raise ValueError(
            f"model card {json_path!r} is missing a non-empty 'classes' list"
        )
    return tuple(str(c) for c in classes)


def ensure_models(
    cache_dir: str | os.PathLike[str] = DEFAULT_CACHE_DIR,
    *,
    version: str = "0.1.0",
) -> ModelSet:
    """Download (if missing) + verify both pins, then load via Essentia.

    Called once per worker via ``Pool(initializer=...)`` so the heavy
    ~250 MB Essentia + TF wheel only imports once per process. The
    returned ``ModelSet`` is reused across every track in that worker.

    Raises :py:class:`ValueError` on hash mismatch (deletes + re-fetches
    once via mirror URLs first; only fails after the mirror loop is
    exhausted). Raises whatever the underlying ``urllib`` raises on
    persistent network failure.
    """
    # Fetch the pinned graph files + their JSON model cards in one
    # pass. Hash failure on any pin is fatal — we don't fall back to
    # an unverified asset.
    musicnn_path = fetch_pinned(MUSICNN_PIN, cache_dir, version=version)
    effnet_path = fetch_pinned(EFFNET_PIN, cache_dir, version=version)
    musicnn_labels_path = fetch_pinned(
        MUSICNN_LABELS_PIN, cache_dir, version=version
    )
    effnet_labels_path = fetch_pinned(
        EFFNET_LABELS_PIN, cache_dir, version=version
    )

    # Lazy import: the heavy `essentia` + TF symbol load is deferred
    # to function body so the module stays importable in environments
    # without the analysis extra installed (unit tests, doc renders).
    import essentia  # type: ignore[import-not-found]
    from essentia.standard import (  # type: ignore[import-not-found]
        TensorflowPredictEffnetDiscogs,
        TensorflowPredictMusiCNN,
    )

    # Essentia logs INFO-level "Successfully loaded graph file" plus
    # WARNING-level "No network created…" lines on every TF predict
    # construction; on a 20-track scan that's ~60 lines of cosmetic
    # noise per worker. Silence them at the source — fatal errors
    # still surface via raised exceptions.
    try:
        essentia.log.infoActive = False
        essentia.log.warningActive = False
    except AttributeError:  # pragma: no cover - defensive
        pass

    musicnn = TensorflowPredictMusiCNN(graphFilename=musicnn_path)

    # Two effnet instances — one for the 400-class predictions head,
    # one for the 1280-d embedding head. Essentia caches the `output`
    # tensor name on construction; sharing one instance and changing
    # `output` between calls is not supported.
    set_template = ModelSet()
    effnet_predictions = TensorflowPredictEffnetDiscogs(
        graphFilename=effnet_path,
        output=set_template.effnet_predictions_output,
    )
    effnet_embedding = TensorflowPredictEffnetDiscogs(
        graphFilename=effnet_path,
        output=set_template.effnet_embedding_output,
    )

    return ModelSet(
        musicnn=musicnn,
        effnet_predictions=effnet_predictions,
        effnet_embedding=effnet_embedding,
        musicnn_classes=_load_labels(musicnn_labels_path),
        effnet_classes=_load_labels(effnet_labels_path),
    )
