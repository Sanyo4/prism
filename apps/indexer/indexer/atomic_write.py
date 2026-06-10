"""Atomic file write via the ``.tmp`` + ``os.rename`` dance.

On Linux ext4/btrfs (the supported FS family for the Syncthing
folder), :py:func:`os.rename` is atomic over a single filesystem.
We open ``<path>.tmp`` in the *same directory* as the target so the
rename never crosses a mount boundary. Cross-FS rename would silently
fall back to ``copy + unlink`` on some FS implementations, breaking
the atomicity guarantee we ship to Syncthing.

Crash semantics:
- Process killed *before* fsync → ``.tmp`` may be partial; ``.sonic.json`` does not exist.
- Process killed *between* fsync and rename → ``.tmp`` is complete; ``.sonic.json`` does not exist.
- Process killed *after* rename → ``.sonic.json`` is the new payload; ``.tmp`` does not exist.

In every case, ``.sonic.json`` is either absent or byte-identical to
the intended payload. A ``.tmp`` left behind by a crash is silently
overwritten on the next scan.
"""

from __future__ import annotations

import os
from pathlib import Path


def atomic_write(path: str | os.PathLike[str], payload: bytes) -> None:
    """Write [payload] to [path] atomically.

    [path] must be on a single filesystem with its parent directory
    (no cross-FS targets). Raises :py:class:`OSError` if the rename
    would cross a mount boundary — better to fail loudly than to
    silently lose atomicity.
    """
    target = Path(os.fspath(path))
    tmp = target.with_name(target.name + ".tmp")

    # Open + write + flush + fsync. We bind the file descriptor to a
    # local so the `with` block closes on every path; the explicit
    # `f.flush()` + `os.fsync()` ensure the bytes hit the platter
    # before the rename, otherwise the rename's atomicity is only
    # over the rename itself, not the contents.
    with open(tmp, "wb") as f:
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())

    # `os.rename` is atomic on the same filesystem on Linux.
    # `os.replace` is the cross-platform alias but adds Windows
    # semantics we don't care about — slice 3 is Linux-only, so the
    # plain rename keeps the failure mode obvious.
    os.rename(tmp, target)
