# Slice 3 kickoff prompt

Paste the entire fenced block below into a fresh Claude Code chat opened
against `/home/sanyo/Projects/music-player`.

**Prerequisites:** Linux x86_64 host (verified by the slice itself). Python 3.11+
available (Pop!_OS 24.04 ships 3.12 as `python3` — fine). Slice 3 is **independent
of slice 1** — it can run in parallel on a separate branch.

---

````
I'm executing slice 3 of Prism: a Linux-only Python 3 CLI (`prism-indexer`) that walks a music folder and writes `.sonic.json` sidecars next to each audio file using Essentia + two TensorFlow models. The repo is at /home/sanyo/Projects/music-player.

This slice has zero Flutter / Dart involvement. Don't touch apps/mobile, packages/, or melos.yaml. Slice 3 lives entirely under apps/indexer/.

## Read in order before doing anything else

1. /home/sanyo/Projects/music-player/docs/spec.md — sidecar format is locked here. The JSON your code emits must match `docs/spec.md` byte-exact (field names, ordering, units, types).
2. /home/sanyo/Projects/music-player/docs/plans/README.md — slice index, "Indexer is Linux-only" invariant.
3. /home/sanyo/Projects/music-player/docs/plans/slice-03-essentia-indexer.md — the slice you're executing.

## Step 0 — verify host

Confirm `uname -m` returns `x86_64` and you're on Linux. The first thing the indexer itself does at runtime is hard-fail on non-Linux-x86_64 hosts; if your build host doesn't qualify, stop and report — Essentia wheels and the model files only exist for this target.

## Set up the Python environment

Create a venv inside `apps/indexer/` (NOT a system-wide install — keep this isolated per-project):

```
mkdir -p apps/indexer
cd apps/indexer
python3 -m venv .venv
source .venv/bin/activate
```

Then install the slice's deps after the doc refresh below tells you the right package names + version pins. `essentia-tensorflow` may pin to a specific Python minor — check before pinning to 3.12.

## Before writing ANY Python

Slice 3 §4 lists docs to refresh: Essentia (essentia.upf.edu/documentation.html), the two model cards (musicnn-msd-2 and discogs-effnet-bs64-1 on essentia.upf.edu/models.html), click, multiprocessing.Pool, and the TF graph loader API (`TensorflowPredictMusiCNN`, `TensorflowPredict2D`). Your training data on Essentia's algorithm signatures and the model URLs is likely stale. Write a ≤5-line "API summary" per library; keep in conversation, do not commit. The model SHA256 pins go in `indexer/models.py` as literal hex strings — get the current values from the model cards during the refresh.

## Execution

Follow slice 3 §8 step-by-step. The file layout in §6 is fixed. Stop at each step's pass criterion.

## Hard constraints

- **Linux x86_64 ONLY.** macOS, Windows, Android, BSD, non-x86_64 Linux: refuse to execute with `sys.exit(1)` and a pointer to `docs/spec.md`. No "best-effort" fallbacks.
- **Sidecar JSON byte-exact to spec.** Same field names, same insertion order (Python dict order ≥3.7 is insertion-ordered — exploit it), same units (LUFS, dB, Hz, sec, BPM), same dtypes (Python `float`, NOT numpy `float32` wrappers — convert with `.tolist()` or `float()`).
- **Atomic sidecar writes.** Write to `<track>.sonic.json.tmp` in same dir → `os.fsync` → `os.rename`. Never leave a partial `.sonic.json` on disk.
- **Resumable scans.** Skip a track if existing sidecar's `audio_sha1` + `analyzer_models` + `schema_version` match. Re-analyze on any mismatch.
- **No SQLite. No HTTP (except first-run model fetch). No Flutter.** Slice 4 owns the cache; slice 2 owns metadata; the phone is a passive consumer.
- **No daemon / watch mode.** One-shot per invocation.
- **CPU only.** TF on Essentia's bundled CPU backend. No GPU paths.

## When done

Run §11 verification + check §12 DoD. The key passes: 20-track folder → 20 sidecars; second run → 0 re-analyses; touch one file → 1 re-analysis; sidecar JSON diff vs `docs/spec.md` example is zero.
````
