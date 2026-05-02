"""Verifies the model fetcher's verify-on-disk + delete-and-refetch
contract using an injectable fetcher (no real network access).
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from indexer.models import (
    ModelPin,
    fetch_pinned,
    sha256_of_file,
)


def _payload(content: bytes) -> tuple[bytes, str]:
    """Return (content, sha256_hex) so tests can mint pins matching
    arbitrary bytes without hand-computing hashes.
    """
    return content, hashlib.sha256(content).hexdigest()


def test_cache_hit_short_circuits(tmp_path: Path) -> None:
    payload, digest = _payload(b"good model bytes")
    pin = ModelPin(
        name="m",
        url="https://example/m.pb",
        sha256=digest,
        relpath="m.pb",
    )
    # Pre-seed cache.
    target = tmp_path / pin.relpath
    target.write_bytes(payload)

    calls: list[str] = []

    def fetcher(url: str, dest: str) -> None:
        calls.append(url)
        Path(dest).write_bytes(b"new bytes (should not run)")

    out = fetch_pinned(pin, str(tmp_path), version="test", fetcher=fetcher)
    assert out == str(target)
    assert calls == [], "cached file with matching digest must skip fetch"


def test_corrupt_cache_is_replaced_via_fetch(tmp_path: Path) -> None:
    payload, digest = _payload(b"good model bytes")
    pin = ModelPin(
        name="m",
        url="https://example/m.pb",
        sha256=digest,
        relpath="m.pb",
    )
    target = tmp_path / pin.relpath
    target.write_bytes(b"WRONG BYTES")

    def fetcher(url: str, dest: str) -> None:
        Path(dest).write_bytes(payload)

    out = fetch_pinned(pin, str(tmp_path), version="test", fetcher=fetcher)
    assert out == str(target)
    assert target.read_bytes() == payload


def test_primary_failure_falls_back_to_mirror(tmp_path: Path) -> None:
    payload, digest = _payload(b"good model bytes")
    pin = ModelPin(
        name="m",
        url="https://primary/m.pb",
        mirror_urls=("https://mirror/m.pb",),
        sha256=digest,
        relpath="m.pb",
    )

    calls: list[str] = []

    def fetcher(url: str, dest: str) -> None:
        calls.append(url)
        if url == "https://primary/m.pb":
            raise OSError("primary down")
        Path(dest).write_bytes(payload)

    out = fetch_pinned(pin, str(tmp_path), version="test", fetcher=fetcher)
    assert out == str(tmp_path / "m.pb")
    assert calls == ["https://primary/m.pb", "https://mirror/m.pb"]


def test_hash_mismatch_after_fetch_raises(tmp_path: Path) -> None:
    pin = ModelPin(
        name="m",
        url="https://primary/m.pb",
        sha256="0" * 64,  # never matches
        relpath="m.pb",
    )

    def fetcher(url: str, dest: str) -> None:
        Path(dest).write_bytes(b"any bytes")

    with pytest.raises(ValueError, match="failed to fetch a verified"):
        fetch_pinned(pin, str(tmp_path), version="test", fetcher=fetcher)
    # Bad bytes must not survive on disk.
    assert not (tmp_path / "m.pb").exists()


def test_empty_pin_sha_refuses(tmp_path: Path) -> None:
    pin = ModelPin(name="m", url="https://x/m.pb", sha256="", relpath="m.pb")
    with pytest.raises(ValueError, match="no SHA256 set"):
        fetch_pinned(pin, str(tmp_path), version="test")


def test_sha256_of_file_matches_hashlib(tmp_path: Path) -> None:
    target = tmp_path / "blob"
    payload = b"some bytes" * 100_000  # 1 MB-ish to exercise the chunk loop
    target.write_bytes(payload)
    expected = hashlib.sha256(payload).hexdigest()
    assert sha256_of_file(target) == expected
