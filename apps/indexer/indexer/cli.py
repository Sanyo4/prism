"""Click-based CLI entry point.

The platform guard fires *before* click dispatches so an
unsupported-platform exit doesn't even surface a usage message —
the user gets the platform-refusal text and a non-zero exit code.

Phase B wires the `scan` command body to a multiprocessing worker
pool that decodes + analyzes every supported audio file under PATH
and writes a ``.sonic.json`` sidecar next to each.
"""

from __future__ import annotations

import os
import sys
from collections import Counter
from multiprocessing import get_context
from typing import Iterator

import click

from indexer import __version__
from indexer.atomic_write import atomic_write
from indexer.models import DEFAULT_CACHE_DIR, ModelSet, ensure_models
from indexer.pipeline import (
    AUDIO_EXTENSIONS,
    AnalysisResult,
    SkipReason,
    analyze,
    sidecar_path_for,
)
from indexer.platform_guard import assert_supported_platform


# --- worker process plumbing ------------------------------------------------
#
# multiprocessing.Pool calls `_init_worker` once per process. The
# loaded `ModelSet` lives in a module-level slot so subsequent
# `_worker_main` calls reuse the same in-process Essentia / TF
# graphs without re-loading 22 MB of `.pb` per track.

_WORKER_MODELS: ModelSet | None = None
_WORKER_FORCE: bool = False


def _init_worker(cache_dir: str, force: bool) -> None:
    """Pool initializer. Loads the models once and caches them on the
    forked worker's module globals. Setting both globals here keeps
    the per-task call (`_worker_main`) signature small.
    """
    global _WORKER_MODELS, _WORKER_FORCE
    _WORKER_MODELS = ensure_models(cache_dir)
    _WORKER_FORCE = force


def _worker_main(path: str) -> tuple[str, str, str]:
    """Per-track worker. Runs `analyze`, writes the sidecar atomically
    on success, and returns a ``(path, status, detail)`` triple the
    parent aggregates into the run summary.

    The triple-of-strings return type is deliberate: we don't pickle
    ``AnalysisResult`` / ``SkipReason`` across the pool boundary
    because ``AnalysisResult`` carries a 1280-d embedding tuple per
    track and re-pickling it for the parent's progress bar would
    move ~10 KB per success across the IPC pipe for nothing.
    """
    if _WORKER_MODELS is None:  # pragma: no cover - initializer ran
        return (path, "decode_failed", "worker not initialized")
    outcome = analyze(path, _WORKER_MODELS, force=_WORKER_FORCE)
    if isinstance(outcome, AnalysisResult):
        target = sidecar_path_for(path)
        try:
            atomic_write(target, outcome.sidecar.to_json_bytes())
        except OSError as e:
            return (path, "decode_failed", f"write {target}: {e}")
        return (path, "analyzed", "")
    assert isinstance(outcome, SkipReason)
    return (path, outcome.reason, outcome.detail)


# --- file walker ------------------------------------------------------------


def _walk_audio_files(root: str) -> Iterator[str]:
    """Yield audio-file paths under ``root``, sorted within each
    directory for stable run-to-run iteration order.

    Symlinked directories are not followed (slice 3 §10 risk 5: avoid
    library-fanout via symlink); symlinked files are followed
    transparently by `open()` so a single-file symlink is treated like
    its target. The frozenset extension filter mirrors `pipeline.AUDIO_EXTENSIONS`.

    Excludes Syncthing conflict files at the walk level so they don't
    even reach the worker (the worker would skip them too, but
    bouncing them through IPC is wasteful).
    """
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        # Sort in place so the run is deterministic — tests rely on it.
        dirnames.sort()
        filenames.sort()
        for name in filenames:
            if "sync-conflict" in name:
                # Both audio files and sidecars matching the conflict
                # pattern are left alone.
                continue
            ext = os.path.splitext(name)[1].lower()
            if ext not in AUDIO_EXTENSIONS:
                continue
            yield os.path.join(dirpath, name)


# --- click commands ---------------------------------------------------------


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
        "max(1, cpu_count - 1) at runtime."
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
@click.option(
    "--cache-dir",
    type=click.Path(file_okay=False, dir_okay=True),
    default=DEFAULT_CACHE_DIR,
    show_default=True,
    help="Directory holding pinned Essentia model files.",
)
def scan(path: str, workers: int | None, force: bool, cache_dir: str) -> None:
    """Walk PATH recursively, analyze each audio file, write sidecars.

    Atomic writes mean a crash mid-run never leaves a partial
    sidecar on disk.
    """
    # Compute the default-worker count *here*, not at module-import
    # time — the slice plan §4 calls this out explicitly: import-
    # time defaults break process pools that fork after a different
    # cpu_count was observed.
    if workers is None:
        cpu = os.cpu_count() or 1
        workers = max(1, cpu - 1)
    workers = max(1, int(workers))

    # Eagerly enumerate so the progress bar has a known total. The
    # walker is fast (stat-only) and the listing usually fits in
    # memory comfortably even for 50k+ track libraries.
    paths = list(_walk_audio_files(path))
    total = len(paths)
    if total == 0:
        click.echo(f"prism-indexer: no audio files under {path!r}", err=True)
        return

    # tqdm is optional at import time so unit tests can run without
    # the wheel; the production install brings it in via pyproject.
    try:
        from tqdm import tqdm  # type: ignore[import-not-found]

        progress = tqdm(total=total, unit="track", dynamic_ncols=True)
    except ImportError:  # pragma: no cover - tqdm is in install_requires
        progress = None

    counter: Counter[str] = Counter()
    failures: list[tuple[str, str]] = []

    # Use the "fork" start method explicitly — slice 3 is Linux-only
    # and `fork` lets the child inherit the already-imported parent
    # state without re-importing TensorFlow per worker.
    ctx = get_context("fork")
    with ctx.Pool(
        processes=workers,
        initializer=_init_worker,
        initargs=(cache_dir, force),
    ) as pool:
        for outcome_path, status, detail in pool.imap_unordered(
            _worker_main, paths, chunksize=1
        ):
            counter[status] += 1
            if status == "decode_failed":
                failures.append((outcome_path, detail))
            if progress is not None:
                progress.update(1)
                progress.set_postfix(
                    {
                        "ok": counter["analyzed"],
                        "skip": counter["sidecar_up_to_date"],
                        "fail": counter["decode_failed"],
                    }
                )

    if progress is not None:
        progress.close()

    # --- run summary ---
    click.echo("")
    click.echo(f"prism-indexer scan {path}")
    click.echo(f"  total      : {total}")
    click.echo(f"  analyzed   : {counter['analyzed']}")
    click.echo(f"  up-to-date : {counter['sidecar_up_to_date']}")
    click.echo(f"  conflict   : {counter['sync_conflict']}")
    click.echo(f"  failed     : {counter['decode_failed']}")
    if failures:
        click.echo("  failures:")
        for fpath, detail in failures[:10]:
            click.echo(f"    - {fpath}: {detail}")
        if len(failures) > 10:
            click.echo(f"    ... and {len(failures) - 10} more")

    # Exit code 1 if any track failed, 0 otherwise. Skip-as-up-to-date
    # is a normal outcome, not an error.
    if counter["decode_failed"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
