# Slice 8 kickoff prompt

Paste the entire fenced block below into a fresh Claude Code chat opened
against `/home/sanyo/Projects/music-player`.

**Prerequisites:** slices 1, 4, 5, 6 merged to `main`. Pixel 9 Pro Fold
connected via USB with developer options + USB debugging enabled
(`adb devices` should list the serial).

---

````
I'm executing slice 8 of Prism: Android Cactus LLM bringing the slice-6 vibe-to-playlist flow to phone, on-device, offline, fully native. The repo is at /home/sanyo/Projects/music-player. Slices 1, 4, 5, 6 are merged. Pixel 9 Pro Fold is connected.

Nothing about `PlaylistEngine`, `FlowScorer`, `Camelot`, `TrackRepo`, or the two slice-6 prompts changes. The interface slice 6 locked is the contract slice 8 honors; the deliverable is a provider swap (`MobileBackend implements LlmBackend`) plus the infrastructure to ship, store, load, and unload a ~1 GB model gracefully on a phone.

## Read in order before doing anything else

1. /home/sanyo/Projects/music-player/docs/spec.md — model lock, Cactus on Android, "phone is read-only consumer" caveat narrowing here to "phone runs LLM but never re-analyzes audio".
2. /home/sanyo/Projects/music-player/docs/plans/README.md — slice index.
3. /home/sanyo/Projects/music-player/docs/plans/slice-08-android-cactus-llm.md — the slice you're executing.
4. /home/sanyo/Projects/music-player/docs/plans/slice-06-desktop-llm-playlists.md — the slice whose interface this slice mirrors. Re-skim §7 (LlmBackend abstract class) and the prompt files.

## Confirm Pixel is reachable

`adb devices` should show the Pixel 9 Pro Fold's serial. If not, stop and tell the user to enable USB debugging.

## Before writing ANY Dart

Slice 8 §4 lists docs to refresh: **Cactus Flutter SDK** (github.com/cactus-compute/cactus, especially the Flutter binding under `/flutter/`), the HuggingFace model card for `Cactus-Compute/Qwen3-1.7B`, and crypto + path_provider + dio Range-request patterns for the resumable downloader. Cactus's API is evolving — verify the OpenAI-compat chat surface, the streaming token callback signature, the `format: "json"` honor, and the `<tool_call>` parsing behaviour. Confirm Tensor G4 NPU support state (it was added March 2026; the binding may need a `backend: 'npu'` flag with CPU fallback). Write ≤5-line summaries.

## Execution

Follow slice 8 §8 step-by-step. New package: `packages/llm_mobile`. Single seam: `llmBackendProvider` in `apps/mobile/lib/main.dart` becomes `Platform.isAndroid ? MobileBackend() : DesktopBackend()`. The `PlaylistEngine` call site is unchanged.

## Hard constraints

- **NOT GGUF. NOT llama.cpp.** Cactus uses its own zero-copy graph engine and a Cactus-specific INT4 packed weight format from their conversion toolchain. Do not reach for GGUF readers.
- **NOT Qwen2.5 anywhere.** Cactus does not support it. Locked: `Cactus-Compute/Qwen3-1.7B`.
- **Reuse slice 6's prompt files byte-for-byte.** `kIntentSystem`, `kIntentSchema`, `kNarrativeSystem`. Any on-device-specific repair (Qwen3-on-Cactus JSON quirks) lives in a `MobileJsonRepair` cleaner on the **response** side ONLY, never in the prompts themselves.
- **NPU-aware init with CPU fallback.** On NPU bind failure (Tensor G4 quirk, unsupported tier), retry with `backend: cpu` and surface "Running on CPU — slower but works offline" in the UI.
- **Lifecycle:** model loads on first AI-tab use, stays resident while the tab is foregrounded, released after 5 min idle or on `onTrimMemory(TRIM_MEMORY_RUNNING_LOW)`.
- **No auto-download on first launch.** Show a "Download model" banner; 1 GB blind transfer is hostile. Resumable via dio Range, SHA256-verified, with size + ETA + pause/resume.
- **No background / notification-backed downloads.** Runs while Settings → LLM is foregrounded; pause leaves a resumable `.partial`.
- **No Cactus on Linux.** Desktop keeps Ollama. Do not attempt source builds for Linux.
- **No tool-call invocation.** Parse `<tool_call>` defensively, never execute.
- **No user-editable prompts or temperature.** Same lock as slice 6.

## When done

Run §11 verification + check §12 DoD. Key external truth: phone in airplane mode → AI tab → "Download model" → wait → coherent 12-track playlist on the same prompt as slice 6's desktop run, qualitatively comparable quality.
````
