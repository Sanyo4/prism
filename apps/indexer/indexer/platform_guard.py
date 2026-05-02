"""Refuse to run anywhere except Linux x86_64.

Slice 3 §2 of the plan locks this in: the indexer ships sidecars to
the phone via Syncthing, the phone is read-only, and we keep a single-
writer invariant. Allowing the indexer on macOS / Windows / Android
would (a) reintroduce sync-conflict sidecars from two writers, (b)
spawn (rather than fork) workers on macOS so models re-import per
file, and (c) break the test matrix that CI doesn't cover.

The guard is its own module so `cli.py` can call it before click
dispatches — exiting with a clear message before any subcommand-
specific imports run.
"""

from __future__ import annotations

import platform
import sys
from typing import Final

#: Public identity strings checked elsewhere (e.g. tests). Pinned here
#: so a grep for "linux" + "x86_64" lands on this module.
SUPPORTED_OS: Final[str] = "linux"
SUPPORTED_MACHINE: Final[str] = "x86_64"

#: Exit code surfaced to the shell on platform refusal. `2` matches
#: argparse's "usage error" convention; click reserves `1` for runtime
#: failures and we want a distinct code so wrappers can branch on it.
EXIT_PLATFORM_UNSUPPORTED: Final[int] = 2


def assert_supported_platform() -> None:
    """Exit non-zero with a pointer to docs/spec.md when the current
    platform is unsupported. Returns ``None`` (and is a no-op) on
    Linux x86_64.

    The check uses ``sys.platform`` (string, e.g. ``"linux"``,
    ``"darwin"``, ``"win32"``) and ``platform.machine()`` (string,
    e.g. ``"x86_64"``, ``"aarch64"``, ``"arm64"``). Both are
    monkeypatchable in tests; the test suite covers darwin + arm64.
    """
    current_os = sys.platform
    current_machine = platform.machine()

    if current_os == SUPPORTED_OS and current_machine == SUPPORTED_MACHINE:
        return

    reason = _build_unsupported_message(current_os, current_machine)
    print(reason, file=sys.stderr)
    raise SystemExit(EXIT_PLATFORM_UNSUPPORTED)


def _build_unsupported_message(current_os: str, current_machine: str) -> str:
    """Render the stderr message. Kept pure so tests can assert on the
    string without spawning a subprocess.
    """
    return (
        "prism-indexer refuses to run on this platform.\n"
        f"  Detected: os={current_os!r}, machine={current_machine!r}\n"
        f"  Supported: os={SUPPORTED_OS!r}, machine={SUPPORTED_MACHINE!r}\n"
        "Linux x86_64 is the only supported platform — see\n"
        "docs/spec.md, §Architecture: the indexer is the single sidecar\n"
        "writer in the system, and Syncthing replicates its output to\n"
        "phones. Running elsewhere is a deliberate non-goal."
    )
