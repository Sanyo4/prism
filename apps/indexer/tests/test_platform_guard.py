"""Verifies the slice-3 platform guard refuses to run on anything but
Linux x86_64. We monkeypatch ``sys.platform`` + ``platform.machine``
rather than running on real macOS/Windows; the production failure mode
is identical.
"""

from __future__ import annotations

import platform
import sys

import pytest

from indexer import platform_guard


def test_linux_x86_64_passes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    # No exception, no exit.
    platform_guard.assert_supported_platform()


def test_macos_exits_with_code_2(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(platform, "machine", lambda: "arm64")
    with pytest.raises(SystemExit) as excinfo:
        platform_guard.assert_supported_platform()
    assert excinfo.value.code == platform_guard.EXIT_PLATFORM_UNSUPPORTED
    err = capsys.readouterr().err
    assert "Linux" in err
    assert "darwin" in err
    assert "docs/spec.md" in err


def test_linux_arm64_exits_with_code_2(monkeypatch: pytest.MonkeyPatch) -> None:
    # aarch64 / arm64 Linux is unsupported per slice 3 §2.
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setattr(platform, "machine", lambda: "aarch64")
    with pytest.raises(SystemExit) as excinfo:
        platform_guard.assert_supported_platform()
    assert excinfo.value.code == platform_guard.EXIT_PLATFORM_UNSUPPORTED


def test_windows_exits_with_code_2(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(platform, "machine", lambda: "AMD64")
    with pytest.raises(SystemExit) as excinfo:
        platform_guard.assert_supported_platform()
    assert excinfo.value.code == platform_guard.EXIT_PLATFORM_UNSUPPORTED


def test_unsupported_message_is_pure(monkeypatch: pytest.MonkeyPatch) -> None:
    """The message-building function is pure — the test asserts on the
    returned string without invoking sys.exit or stderr.
    """
    msg = platform_guard._build_unsupported_message("darwin", "arm64")
    assert "prism-indexer" in msg
    assert "darwin" in msg
    assert "arm64" in msg
    assert "Linux" in msg
    assert "x86_64" in msg
    assert "docs/spec.md" in msg
