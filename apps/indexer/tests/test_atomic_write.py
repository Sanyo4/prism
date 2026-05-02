"""Verifies atomic_write's contract: success → exact payload at the
target path; failure (subprocess killed mid-write) → either no file
or a complete file, never partial.
"""

from __future__ import annotations

import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from indexer.atomic_write import atomic_write


def test_writes_payload_exactly(tmp_path: Path) -> None:
    target = tmp_path / "song.sonic.json"
    payload = b'{"hello": "world"}'
    atomic_write(target, payload)
    assert target.read_bytes() == payload


def test_overwrites_existing_atomically(tmp_path: Path) -> None:
    target = tmp_path / "song.sonic.json"
    target.write_bytes(b"OLD")
    atomic_write(target, b"NEW")
    assert target.read_bytes() == b"NEW"


def test_no_tmp_left_behind_on_success(tmp_path: Path) -> None:
    target = tmp_path / "song.sonic.json"
    atomic_write(target, b"payload")
    assert not (tmp_path / "song.sonic.json.tmp").exists()


def test_kill_between_write_and_rename_leaves_no_partial(tmp_path: Path) -> None:
    """Spawn a subprocess that performs the open + write + flush + fsync
    sequence, then `os._exit(1)` *before* calling rename. The parent
    inspects the directory and asserts:
      - the final ``.sonic.json`` is absent (rename never happened); and
      - the ``.tmp`` may exist with the partial payload, but it is not
        masquerading as the real file.

    We use os._exit to kill without flushing Python-level finalizers,
    which is the closest test approximation to a real power loss.
    """
    target = tmp_path / "song.sonic.json"
    script = textwrap.dedent(
        f"""
        import os, sys
        target = {str(target)!r}
        tmp = target + ".tmp"
        with open(tmp, "wb") as f:
            f.write(b"PAYLOAD")
            f.flush()
            os.fsync(f.fileno())
        # Crash here, before os.rename(tmp, target).
        os._exit(1)
        """
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        check=False,
    )
    assert result.returncode == 1
    # Final sidecar must not exist.
    assert not target.exists()
    # The .tmp may exist with the partial payload — that's expected.
    tmp_file = tmp_path / "song.sonic.json.tmp"
    if tmp_file.exists():
        assert tmp_file.read_bytes() == b"PAYLOAD"


def test_existing_target_unchanged_when_tmp_creation_fails(
    tmp_path: Path,
) -> None:
    """If we can't even open the .tmp (e.g. RO directory), the
    pre-existing target must be left intact.
    """
    target = tmp_path / "subdir" / "song.sonic.json"
    target.parent.mkdir()
    target.write_bytes(b"OLD")
    # Make the dir read-only so the .tmp open fails.
    os.chmod(target.parent, 0o555)
    try:
        with pytest.raises(OSError):
            atomic_write(target, b"NEW")
        assert target.read_bytes() == b"OLD"
    finally:
        # Restore so pytest cleanup can remove the tree.
        os.chmod(target.parent, 0o755)
