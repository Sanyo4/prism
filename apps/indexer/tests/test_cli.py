"""Smoke-test the click skeleton:
- `prism-indexer --help` lists `scan`.
- `prism-indexer --version` prints the package version.
- `prism-indexer scan <empty-dir>` reports zero-files and exits 0
  without going near the worker pool / model loader.

We don't run the platform guard here — the test runs on Linux x86_64
and the guard is covered by `test_platform_guard.py`. We don't run
the actual analysis pipeline either — that's covered by the
end-to-end test in `test_resume.py`.
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


def test_scan_empty_dir_reports_no_files(tmp_path: Path) -> None:
    """Empty directory → friendly stderr + exit 0. The walker
    short-circuits before constructing the worker pool, so this
    runs without `essentia-tensorflow` loaded.
    """
    result = CliRunner().invoke(main, ["scan", str(tmp_path)])
    assert result.exit_code == 0, result.output
    assert "no audio files" in result.output.lower()


def test_scan_rejects_missing_path() -> None:
    result = CliRunner().invoke(main, ["scan", "/this/path/does/not/exist"])
    assert result.exit_code == 2
    # click's own error message for a missing path.
    assert "does not exist" in result.output.lower() or "invalid value" in result.output.lower()
