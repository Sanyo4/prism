"""Smoke-test the click skeleton:
- `prism-indexer --help` lists `scan`.
- `prism-indexer --version` prints the package version.
- `prism-indexer scan <empty-dir>` exits with the Phase A "not
  implemented" UsageError. (Phase B replaces this with the real run.)

We don't run the platform guard here — the test runs on Linux x86_64
and the guard is covered by `test_platform_guard.py`.
"""

from __future__ import annotations

from pathlib import Path

from click.testing import CliRunner

from indexer import __version__
from indexer.cli import main


def test_help_lists_scan_subcommand() -> None:
    result = CliRunner().invoke(main, ["--help"])
    assert result.exit_code == 0, result.output
    assert "scan" in result.output


def test_version_flag_prints_version() -> None:
    result = CliRunner().invoke(main, ["--version"])
    assert result.exit_code == 0, result.output
    assert __version__ in result.output


def test_scan_phase_a_raises_usage_error(tmp_path: Path) -> None:
    """Phase A: the scan body raises a click UsageError so a curious
    user knows the slice isn't done yet. Phase B replaces this body
    with the real worker pool dispatch.
    """
    result = CliRunner().invoke(main, ["scan", str(tmp_path)])
    # Click's UsageError exits 2.
    assert result.exit_code == 2
    assert "Phase B" in result.output


def test_scan_rejects_missing_path() -> None:
    result = CliRunner().invoke(main, ["scan", "/this/path/does/not/exist"])
    assert result.exit_code == 2
    # click's own error message for a missing path.
    assert "does not exist" in result.output.lower() or "invalid value" in result.output.lower()
