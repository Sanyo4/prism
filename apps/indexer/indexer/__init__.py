"""prism-indexer — Linux x86_64-only sonic-analysis CLI.

Public surface:
- ``SidecarV1`` / ``CURRENT_SCHEMA_VERSION`` — sidecar dataclass + the
  schema version slice 4's ingest checks.
- ``ANALYZER_ID`` / ``ANALYZER_MODELS`` — analyzer identity strings the
  resume check compares against existing sidecars.

Importing this package does **not** import Essentia or TensorFlow —
those land lazily inside ``indexer.pipeline`` so the scaffold is unit-
testable in environments without the heavy wheels installed.
"""

from indexer.sidecar import (
    ANALYZER_ID,
    ANALYZER_MODELS,
    CURRENT_SCHEMA_VERSION,
    SidecarV1,
)

__all__ = [
    "ANALYZER_ID",
    "ANALYZER_MODELS",
    "CURRENT_SCHEMA_VERSION",
    "SidecarV1",
]

__version__ = "0.1.0"
