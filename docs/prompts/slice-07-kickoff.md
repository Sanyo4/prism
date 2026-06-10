# Slice 7 kickoff prompt

Paste the entire fenced block below into a fresh Claude Code chat opened
against `/home/sanyo/Projects/music-player`.

**Prerequisites:** slice 2 merged at minimum (slice 2 added the surfaces this
polishes); slices 4, 5, 6 also done in practice — slice 7 polishes ALL
surfaces from earlier slices in one pass. Run last among 1–6.

---

````
I'm executing slice 7 of Prism: Apple Music visual polish — typography, spacing, hero transitions, and adaptive palette. The repo is at /home/sanyo/Projects/music-player. Slices 1, 2, 4, 5, 6 (and ideally 3) are merged. **No new features in this slice.**

This slice is a purely visual pass over screens already built. New routes: zero. New stores: zero. New data shapes: zero. What changes is how existing screens *feel*: typography scale, spacing grid, hero flights album-tile → album-detail → now-playing, and adaptive palette on the two hero surfaces.

## Read in order before doing anything else

1. /home/sanyo/Projects/music-player/docs/spec.md — visual scope is intentionally light here; the stack is locked.
2. /home/sanyo/Projects/music-player/docs/plans/README.md — slice index.
3. /home/sanyo/Projects/music-player/docs/plans/slice-07-apple-music-polish.md — the slice you're executing.
4. /tmp/design-extract/music/project/ui/primitives.jsx — the design bundle that pins the Glass / AuroraBackground aesthetic. If this path doesn't exist, ask the user where the design bundle lives.

## Before writing ANY Dart

Slice 7 §4 lists docs to refresh: palette_generator (algorithm + cache shape), Hero widget API + the three-concurrent-hero pattern (Flutter docs), ThemeExtension idiom, font loading via `google_fonts` or local-asset (Inter + Geist bundled, SF Pro is hint-only). Write ≤5-line summaries.

## Execution

Follow slice 7 §8 step-by-step. Six new files in `packages/ui/` (the new pure-Dart UI package); the rest is edits to existing screens to consume `SpaceTokens` + `TypographyScale` + (on hero surfaces only) `AlbumPalette`.

## Hard constraints

- **No new features.** If you find yourself adding a new screen, route, store, provider, or data shape — stop. That's a different slice.
- **Five fallback presets are LOCKED:** `#6ba8ff` blue, `#ffa0c8` pink, `#a0e8c4` mint, `#ffc878` amber, `#c0a0ff` lilac. Used when album art is too low-chroma. User picks default in Settings → Theme; default is **blue**. These five values are also the AuroraBackground variant accents — they match.
- **Adaptive palette ONLY on album-detail and now-playing.** Everything else stays on neutral tokens. No chromatic whiplash.
- **No dark mode.** Aurora is inherently light. Dark mode requires different blob set + different Glass blur math + a second palette tuple per album. Punt.
- **No animated Aurora.** Static, blurred, grain-overlaid backdrop. Faster, quieter, battery-safe.
- **Six files in `packages/ui/`, no more.** Glass + AuroraBackground are the only primitives hoisted. AeroSlider / ChromeButton remain in-app wrappers over Material.
- **Typography scale is fixed: display 36/28/20, body 16, caption 13.** Display line-height 1.15, body 1.45. Stack: SF Pro Display → Inter → Geist (SF Pro is opportunistic on Apple devices; falls back gracefully on Android/Linux).
- **Spacing scale is fixed: 4, 8, 12, 16, 24, 32, 48 px.** Consumed via `ThemeExtension<SpaceTokens>`. Every touched widget references named tokens, not literals.
- **Settings, Search, and Library browse grids stay neutral.** No album-derived accents on those surfaces. They adopt the new type/space tokens but not the AlbumPalette extension.

## When done

Run §11 verification + check §12 DoD. Key external truth: side-by-side screenshots of album detail, now-playing, and browse vs. Apple Music feel cohesive — same generous whitespace, same hero treatment, same warmth. The hero flight album-tile → album-detail → now-playing animates without visible jump.
````
