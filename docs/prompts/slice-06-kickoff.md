# Slice 6 kickoff prompt

Paste the entire fenced block below into a fresh Claude Code chat opened
against `/home/sanyo/Projects/music-player`.

**Prerequisites:** slice 5 merged to `main`. Ollama daemon running and the
model already pulled — do this in your shell BEFORE starting the session:

```
ollama serve &        # if not already running as a service
ollama pull qwen3:1.7b   # ~1.5 GB, takes a few minutes
```

---

````
I'm executing slice 6 of Prism: desktop LLM playlists. The repo is at /home/sanyo/Projects/music-player. Slices 1, 3, 4, 5 are merged. `packages/playlist_engine` exists with `RadioEngine`, `FlowScorer`, `Camelot`, `PlaylistRepo`. Ollama is running locally and `qwen3:1.7b` is pulled — I have already done this.

This slice is **desktop-only**. It introduces `packages/llm_desktop` (a thin Ollama REST client) and `class PlaylistEngine` in `packages/playlist_engine` beside `RadioEngine`. It also introduces the `LlmBackend` abstract class that **slice 8 will re-implement on Android via Cactus**. Keep that interface tiny.

## Read in order before doing anything else

1. /home/sanyo/Projects/music-player/docs/spec.md — playlist length, model lock, the (vibe → intent → flow → final pass) pipeline.
2. /home/sanyo/Projects/music-player/docs/plans/README.md — slice index. Note that "playlist length 12" supersedes the older "15" in the spec draft.
3. /home/sanyo/Projects/music-player/docs/plans/slice-06-desktop-llm-playlists.md — the slice you're executing.

## Confirm Ollama is reachable

Before any code: `curl -s http://localhost:11434/api/tags` should list `qwen3:1.7b`. If not, stop and tell the user.

## Before writing ANY Dart

Slice 6 §4 lists docs to refresh: dio (already in slice 2 — re-skim only what's new), and **the Ollama REST API** (github.com/ollama/ollama/blob/main/docs/api.md). The endpoints for `/api/generate`, `/api/chat`, `/api/tags`, `/api/pull`, JSON mode (`format: "json"`), and the Qwen3 chat-template behaviour are critical to get right. Your training data on Ollama's response shapes (especially the streaming envelope and `<tool_call>` token leakage) is likely stale. Write a ≤5-line API summary; keep in conversation.

## Execution

Follow slice 6 §8 step-by-step. File layout in §6 is fixed. Stop at each step's pass criterion.

## Hard constraints

- **`LlmBackend` interface stays tiny: `buildIntent` + `refine` + a progress stream.** Anything more (streaming envelopes, model metadata, health probes) lives on the per-backend adapter (OllamaBackend), NOT in the shared abstract class. Slice 8 will re-implement this exact interface for Cactus on Android — keep it implementation-agnostic.
- **Playlist length = 12.** Locked by `docs/plans/README.md`. Not 15 (older spec draft).
- **Model = qwen3:1.7b on Ollama.** Locked because slice 8's Cactus must use the same family (Qwen3-1.7B INT4) and Cactus does not support Qwen2.5.
- **Reuse slice 5's FlowScorer + Camelot unmodified.** The flow step calls `FlowScorer.scoreOrReject` with the same rules.
- **No cloud LLMs.** No OpenAI / Anthropic / Groq / Together routes ever. The spec locks Prism fully local.
- **No streaming playback while LLM thinks.** The 12-track list is returned whole; "Play" loads the whole queue.
- **No user-editable prompts, temperatures, or system messages.** Locked: intent prompt at temp 0.1 with strict JSON schema; narrative prompt at temp 0.7 with ≤4 swaps and a ≤2-sentence blurb.
- **No tool-call invocation.** Parse `<tool_call>` tokens defensively (Qwen3 leaks them in JSON mode) but never execute.
- **No persisted playlists.** Results are ephemeral unless the user drags rows into PlayNext / Upcoming.
- **No change to radio semantics.** Slice 5 stays exactly as-is.

## When done

Run §11 verification + check §12 DoD. Key external truth: type a vibe like "melancholy late-night drive, 90s lean, builds over time" → progress stream shows intent extraction → 12 coherent tracks + a one-line blurb → "Play" loads the queue and plays end-to-end.
````
