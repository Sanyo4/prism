# Per-slice kickoff prompts

One file per slice. Each is a self-contained prompt you paste into a fresh
Claude Code session opened against `/home/sanyo/Projects/music-player`.

## Workflow per slice

1. Open a new chat. Confirm cwd is the repo root.
2. Open the matching `slice-NN-kickoff.md` here.
3. Copy the fenced ```` ``` ```` block (the prompt itself) into the chat.
4. Let it execute the slice. Verify locally between sessions.
5. Commit, merge to `main`, then start the next slice in a fresh chat.

Each prompt assumes the previous slices it depends on are **merged to `main`**,
not just on a branch. Don't start slice N+1 until slice N's verification + DoD
are signed off.

## Slice order

Respects the dependency DAG in `docs/plans/README.md`. Slice 3 is independent
of the Flutter tree and can run in parallel with slice 1 on a separate branch.

| Order | Slice | Why this position |
|---|---|---|
| 1 | `slice-01-kickoff.md` | No deps. Foundational. |
| 1 (parallel) | `slice-03-kickoff.md` | No deps; Python tree, separate branch. |
| 2 | `slice-02-kickoff.md` | Needs slice 1. |
| 3 | `slice-04-kickoff.md` | Needs 1 + 3. |
| 4 | `slice-05-kickoff.md` | Needs 4. |
| 5 | `slice-06-kickoff.md` | Needs 5. |
| 6 | `slice-08-kickoff.md` | Needs 6. |
| any time after 2 | `slice-07-kickoff.md` | Visual polish; latest possible. |
| any time after 1 | `slice-09-kickoff.md` | Cast/DLNA. Independent of LLM/sonic stack. |

## Foundational install (already done if `flutter doctor` is green)

`bash scripts/setup-linux.sh` — Flutter, Android SDK, Linux desktop deps,
melos, Ollama daemon, JDK 17.

## Per-slice prerequisites the foundational install intentionally skips

- **Slice 3**: create a venv inside `apps/indexer/`, install Essentia +
  TensorFlow there. The slice-3 prompt walks through this — keep it
  per-project, not system-wide.
- **Slice 6**: `ollama serve &` then `ollama pull qwen3:1.7b` (~1.5 GB).
  Pull this before starting the slice-6 chat so the model is local.
- **Slice 8**: Cactus weights download from inside the running Android app
  (~1 GB INT4). Done by the app on first AI-tab use.
- **Slice 9**: nothing extra. The Sony STR-DN1080 needs to be on the LAN
  during verification.

## Tips

- Add `Create branch slice-NN. Don't push.` to the bottom of any prompt to
  keep the work isolated.
- Add `Stop after step <N> for me to verify <X> before continuing.` to
  break a long slice into checkpoints.
- If the LLM session goes stale before the slice is done, start a new one
  with the same prompt — the kickoff is idempotent (it'll re-read the
  spec and slice plan, see what's already on disk, and resume).
