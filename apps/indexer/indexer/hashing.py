"""Streaming SHA1 over decoded PCM mono.

The sidecar's ``audio_sha1`` is hashed over the decoded float32 mono
PCM, *not* the source file bytes. Two consequences fall out of that
choice:

1. **Tag edits don't invalidate the sidecar.** Re-muxing a FLAC or
   re-tagging an MP3 leaves the underlying PCM unchanged, so the
   hash stays the same — slice 3 §11 verification 4 ("re-mux with
   identical PCM does not trigger re-analysis") depends on this.

2. **Re-encoding *does* invalidate the sidecar.** Going from FLAC to
   16-bit-truncated FLAC, or from a 24-bit master to a 16-bit master,
   changes the PCM and therefore the hash. The sidecar gets
   re-analyzed on the next scan — also intentional.

We hash the same ``numpy.ndarray`` instance the analyzers consume —
no double read of the source file.
"""

from __future__ import annotations

import hashlib
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import numpy as np  # noqa: F401  (only typed; not imported at runtime here)

#: 1 MiB chunk size. Smaller wastes CPU on call overhead, larger
#: wastes memory on the temporary ``.tobytes()`` slice — 1 MiB lands
#: in the L2/L3 cache range on the reference laptop and is the default
#: for most streaming hash patterns in the stdlib.
_CHUNK_BYTES: int = 1 * 1024 * 1024


def audio_sha1(pcm: "np.ndarray") -> str:
    """Hash a 1-D float32 mono PCM array into a 40-char hex digest.

    Streams the underlying buffer in 1 MiB slices so a 30-minute
    24-bit / 96 kHz track (~700 MB decoded) doesn't allocate a single
    monolithic ``bytes`` object. Returns lowercase hex matching the
    spec's ``audio_sha1`` field.

    Implementation note: ``ndarray.tobytes()`` allocates per call, so
    we slice with ``[start:end]`` first (a view) and then call
    ``.tobytes()`` on the slice to materialise just that 1 MiB.
    """
    # Lazy import keeps `indexer` importable in environments without
    # numpy installed (e.g. doc-only previews). Phase A already lists
    # numpy as a required dep, so this is essentially free.
    import numpy as np

    if pcm.ndim != 1:
        raise ValueError(
            f"audio_sha1 expects 1-D mono PCM; got shape {pcm.shape}"
        )
    if pcm.dtype != np.float32:
        raise ValueError(
            f"audio_sha1 expects float32 PCM; got dtype {pcm.dtype}"
        )

    digest = hashlib.sha1()
    bytes_per_sample = pcm.dtype.itemsize  # 4 for float32
    samples_per_chunk = _CHUNK_BYTES // bytes_per_sample

    n = pcm.shape[0]
    start = 0
    while start < n:
        end = min(start + samples_per_chunk, n)
        digest.update(pcm[start:end].tobytes())
        start = end

    return digest.hexdigest()
