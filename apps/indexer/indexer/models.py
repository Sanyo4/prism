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
    sha256="",  # Filled in by Phase B once the model is downloaded.
    relpath="msd-musicnn-1.pb",
)

EFFNET_PIN: ModelPin = ModelPin(
    name="discogs-effnet-bs64-1",
    url=(
        "https://essentia.upf.edu/models/feature-extractors/discogs-effnet/"
        "discogs-effnet-bs64-1.pb"
    ),
    mirror_urls=(),
    sha256="",  # Filled in by Phase B once the model is downloaded.
    relpath="discogs-effnet-bs64-1.pb",
)


@dataclass(slots=True)
class ModelSet:
    """Runtime container handed to a worker after ``ensure_models``.

    Both Essentia instances are typed as ``object`` because the
    Essentia Python API is dynamic and a strict annotation would drift
    against new wheels. Phase B will populate these from
    ``TensorflowPredictMusiCNN`` and ``TensorflowPredictEffnetDiscogs``;
    Phase A leaves them None so the data structures are testable.
    """

    musicnn: object | None = None
    effnet: object | None = None
    effnet_embedding_output: str = "PartitionedCall:1"
    """Tensor name for the 1280-d penultimate activation. Confirmed
    via the Essentia model card at slice-3 doc-refresh time. A future
    upstream change to the graph internals would require an update
    here — bump along with the model SHA256 pin."""


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


def ensure_models(
    cache_dir: str | os.PathLike[str] = DEFAULT_CACHE_DIR,
    *,
    version: str = "0.1.0",
) -> ModelSet:
    """Download (if missing) + verify both pins, then load via Essentia.

    Phase A returns a ``ModelSet`` with both ``musicnn`` and ``effnet``
    set to ``None`` — the import + load is deferred to the Phase B
    pipeline so the scaffold installs without ``essentia-tensorflow``.

    The fetch loop is fully exercised in Phase A unit tests via the
    ``fetcher`` injection on ``fetch_pinned``.
    """
    # Fetch the pinned files. In Phase A, the empty pin SHA256s make
    # this raise — that's the intended contract before Phase B fills
    # them in. Tests pass populated pins through ``fetch_pinned``
    # directly.
    musicnn_path = fetch_pinned(MUSICNN_PIN, cache_dir, version=version)
    effnet_path = fetch_pinned(EFFNET_PIN, cache_dir, version=version)

    # Phase B will replace these stubs with:
    #   from essentia.standard import (
    #       TensorflowPredictMusiCNN,
    #       TensorflowPredictEffnetDiscogs,
    #   )
    #   musicnn = TensorflowPredictMusiCNN(graphFilename=musicnn_path)
    #   effnet  = TensorflowPredictEffnetDiscogs(graphFilename=effnet_path)
    #   effnet_embedding = TensorflowPredictEffnetDiscogs(
    #       graphFilename=effnet_path,
    #       output=ModelSet().effnet_embedding_output,
    #   )
    #
    # Returning the resolved paths in the meantime lets Phase B wire
    # the loader without rediscovering them.
    _ = (musicnn_path, effnet_path)
    return ModelSet()
