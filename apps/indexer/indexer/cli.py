"""Click-based CLI entry point.

The platform guard fires *before* click dispatches so an
unsupported-platform exit doesn't even surface a usage message —
the user gets the platform-refusal text and a non-zero exit code.

Phase A wires the click skeleton; the ``scan`` command body lands in
Phase B once Essentia is installed. Until then, ``scan`` raises
``click.UsageError`` so a user invoking it sees a clear pointer.
"""

from __future__ import annotations

import os

import click

from indexer import __version__
from indexer.platform_guard import assert_supported_platform


@click.group(name="prism-indexer")
@click.version_option(version=__version__, prog_name="prism-indexer")
def main() -> None:
    """Prism sonic-analysis indexer (Linux x86_64 only)."""
    # Platform guard runs on every invocation; we accept the small
    # cost on `--help` to keep the contract simple ("never run on
    # the wrong platform, period").
    assert_supported_platform()


@main.command(name="scan")
@click.argument(
    "path",
    type=click.Path(
        exists=True,
        file_okay=False,
        dir_okay=True,
        resolve_path=True,
    ),
)
@click.option(
    "--workers",
    type=int,
    default=None,
    help=(
        "Number of analysis worker processes. Defaults to "
        "max(1, cpu_count - 1) at runtime — leaving the option "
        "default unbound here on purpose so a process pool created "
        "on a 4-core build host doesn't override the user's "
        "16-core target."
    ),
)
@click.option(
    "--force",
    is_flag=True,
    default=False,
    help=(
        "Re-analyze every track even when an up-to-date sidecar "
        "exists. Use after bumping schema_version or analyzer "
        "models in source — slice 3 §11 verification 6."
    ),
)
def scan(path: str, workers: int | None, force: bool) -> None:
    """Walk PATH recursively, analyze each audio file, write sidecars.

    The sidecar lives next to the audio file: e.g.
    ``Artist/Album/01 - Song.flac`` produces
    ``Artist/Album/01 - Song.sonic.json``. Atomic writes mean a
    crash mid-run never leaves a partial sidecar on disk.

    Phase A note: this command body is not implemented. Phase B
    wires up the worker pool, the model loader, and the per-track
    pipeline.
    """
    # Compute the default-worker count *here*, not at module-import
    # time — the slice plan §4 calls this out explicitly: import-
    # time defaults break process pools that fork after a different
    # cpu_count was observed.
    if workers is None:
        cpu = os.cpu_count() or 1
        workers = max(1, cpu - 1)

    # Phase B replaces this with the worker-pool dispatch in
    # ``pipeline.run_scan(path, workers=workers, force=force)``.
    raise click.UsageError(
        "`scan` is not implemented yet — Phase B wires the analysis "
        "pipeline once `pip install essentia-tensorflow` lands. "
        "(Resolved args: path={!r}, workers={}, force={}.)".format(
            path, workers, force
        )
    )


if __name__ == "__main__":
    # `python -m indexer.cli` direct-invoke path. The package's
    # `__main__.py` also wires this up for `python -m indexer`.
    main()
