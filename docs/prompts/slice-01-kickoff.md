# Slice 1 kickoff prompt

Paste the entire fenced block below into a fresh Claude Code chat opened
against `/home/sanyo/Projects/music-player`.

---

````
I'm building Prism, a local-first Flutter music player with a Python sonic-analysis indexer. The repo is at /home/sanyo/Projects/music-player. It is currently greenfield — only docs and a setup script exist, no application code yet.

## Read in order before doing anything else

1. /home/sanyo/Projects/music-player/docs/spec.md — authoritative invariants (sidecar format, SQLite schema, stack lock-in, scope boundaries). Do not violate anything here without flagging it.

2. /home/sanyo/Projects/music-player/docs/plans/README.md — slice index, dependency DAG, naming conventions, locked tech stack, and the "Doc refresh protocol" you MUST follow.

3. /home/sanyo/Projects/music-player/docs/plans/slice-01-scaffold-scan-play-queue.md — the slice you're executing this session.

## Step 0 — verify environment

Run `flutter doctor` first. It should be all green except possibly Chrome (web is not a target — ignore). If it's not green, stop and report what's missing; the user will fix it before you proceed.

## Before writing ANY Dart or YAML

Slice 1 §4 ("Docs to refresh") lists exact commands per package: just_audio, audio_service, audiotags, path_provider, flutter_riverpod, melos, plus two Flutter WebFetch URLs. Run every one. Your training data on these APIs is likely wrong — Melos ≥6 integrates with Dart's native `workspace:`, `audiotags`'s custom-fields accessor name shifted between versions, etc. For each package write a ≤5-line "API summary" of what's drifted from your memory; keep them in conversation as scratch notes (not committed).

Only after the doc refresh is complete, start implementation.

## Execution

Follow slice 1 §8 step-by-step (15 numbered steps, each ~20–80 LOC with a one-line pass criterion). Stop at each pass criterion before moving on. The file layout is fixed in §6 — don't invent new files or rename ones listed there. Interface signatures in §7 are the contract.

## Hard constraints

- `packages/core` has zero Flutter imports. Pure Dart only.
- Riverpod, no codegen. (No `riverpod_generator` / `build_runner` in slice 1.)
- No `freezed` in slice 1.
- No measured ReplayGain — only tag-embedded values. Measured RG is slice 4.
- Skip everything in §2 "Non-goals." If you find yourself reaching for browse-by-album, sidecars, LLM, DLNA, or palette theming — stop, that's a later slice.
- AppShell's gear icon must be reachable from every top-level screen. This is a spec invariant.

## When done

Run §11 verification top-to-bottom and check off §12 "Definition of done." Report which items passed automatically, which need manual verification on the Pixel 9 Pro Fold or Linux desktop (gapless audio test, lockscreen, ReplayGain perceptual check), and which (if any) you couldn't complete and why.

Tools available: Flutter stable installed locally, Pixel 9 Pro Fold for Android verification (USB debugging will need to be enabled when slice 1 step 14 runs), Linux laptop for desktop verification.
````
