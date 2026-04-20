# Slice 7 — Apple Music polish: typography, spacing, heroes, adaptive palette

## 1. Context

**No new features.** Slice 7 is a purely visual pass over the screens
built in slices 1–6. No new routes, no new stores, no new data shapes
that the rest of the app did not already have. What changes is how
the existing screens *feel*: the typography scale, the spacing grid,
the transition between album tile → album detail → now-playing, and
the color of the two "hero" surfaces where the album art dominates
the frame.

Slice 7 is intentionally late. Touching theme tokens mid-slice-2 or
mid-slice-5 would force every UI diff after it to rebase on top of a
moving target. Running it now — after slice 1's shell, slice 2's
browse surface, slices 4/5's mood/radio chrome, and slice 6's LLM
sheet — lands the polish once over a settled surface. Slices 8 and
9 add no new screens this slice must anticipate.

The design bundle at `/tmp/design-extract/music/project/ui/
primitives.jsx` pins the aesthetic: frosted `Glass` panes over a
soft Aurora gradient backdrop, with five named variants (`home`,
`album`, `player`, `library`, `ai`). Slice 7 ports that into Flutter
via a new pure-Dart UI package (`packages/ui`) and folds in the
three remaining polish axes the bundle does not encode: type scale,
spacing grid, and hero flights.

## 2. Goals / Non-goals

**Goals**

- Typography scale: display 36 / 28 / 20, body 16, caption 13. Display
  line-height 1.15, body line-height 1.45. Font stack (by priority):
  *SF Pro Display* → *Inter* → *Geist*. Inter + Geist bundled as
  app assets; SF Pro is an opportunistic hint for Apple devices and
  will not resolve on Android/Linux — included in the family list so
  rendering degrades gracefully on platforms that do ship it.
- Spacing scale: `4, 8, 12, 16, 24, 32, 48` px (Material-like,
  non-linear). Consumed via `ThemeExtension<SpaceTokens>`; every
  slice-7-touched widget references named tokens, not literals.
- Hero transitions from *album tile* (in `LibraryScreen` / album grid,
  slice 2 and `RandomTab`) → *album detail* (slice 2) → *now playing*
  (slice 1, expanded layout in slice 5). Three concurrent hero tags
  flow through the animation.
- **Adaptive palette:** on album-art load, compute once via the
  `palette_generator` package and cache the tuple
  `(dominant, secondary, textOnDominant)` to SQLite `metadata_cache`.
  Apply through a dynamic `ThemeExtension<AlbumPalette>` **only on
  album-detail and now-playing**. The rest of the app stays on the
  neutral tokens to avoid chromatic whiplash.
- **Five fallback presets — locked:** `#6ba8ff` (blue), `#ffa0c8`
  (pink), `#a0e8c4` (mint), `#ffc878` (amber), `#c0a0ff` (lilac).
  Used whenever the album art is too gray / low-chroma to yield a
  meaningful accent. User picks the default preset in Settings →
  Theme; the default is *blue*. These five values are the accent
  inputs for AuroraBackground's five variants — they match.
- Promote `Glass` and `AuroraBackground` from the design bundle into
  `packages/ui`. AuroraBackground exposes `AuroraVariant.home | album
  | player | library | ai` and picks its blob set and base gradient
  from that enum.
- Wire the two new `ThemeExtension`s plus the `Glass` / Aurora
  primitives into the existing screens: Home, Library, Album detail,
  Artist detail, Now Playing, Queue, Random, Settings, New Vibe
  sheet. All consume `SpaceTokens` and `TypographyScale`. Only the
  two hero surfaces also consume `AlbumPalette`.

**Non-goals**

- No visual changes to Settings, Search, Library browse lists
  (Albums/Artists/Genres grids) beyond adopting the new type and
  spacing tokens. They stay on the neutral palette; no album-derived
  accents, no adaptive Aurora variant swap.
- No dark mode. Aurora is inherently light; a dark mode requires a
  different blob set, different Glass blur math, and a second
  palette tuple per album. Punt. Slice 7 ships one mode.
- No new `packages/ui` widgets beyond the six files listed in §6.
  `Glass` and `AuroraBackground` are the only primitives hoisted;
  `AeroSlider` / `ChromeButton` remain in-app wrappers over Material.
- No animated Aurora (no motion on blobs). A static, blurred,
  grain-overlaid backdrop is faster, quieter, and battery-safe.
- No gesture-driven hero dismissal. Hero flights use the default
  `MaterialPageRoute` push / pop; slice 7 does not introduce
  custom page routes.
- No drag-handle queue reorder (continues to live in slice 1's
  overflow-menu world for now; slice 7 does not add it despite an
  earlier note in slice 1 suggesting it). Explicit: the reorder
  gesture is its own slice, not polish.

## 3. Dependencies

Depends on: 2
Unblocks: —

Slice 2's on-disk Cover Art Archive cache feeds the palette
extractor. Slice 7 lands *after* slice 2 so art URLs are stable
and `metadata_cache` exists. Slices 3–6 do not block slice 7 —
they add data surfaces that render inside screens slice 7 re-themes.
`docs/plans/README.md` shows `2 ──► 7` as a sibling branch.

## 4. Docs to refresh

Run before writing Dart. Keep a ≤5-line API summary per library.

### `palette_generator`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "palette_generator"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "PaletteGenerator.fromImageProvider dominant vibrant muted region size"`.

**API summary reminder:** `PaletteGenerator.fromImageProvider(
provider, size: Size(200,200), maximumColorCount: 16)` is the
canonical entry. Returned `PaletteColor` swatches expose `.color`,
`.bodyTextColor`, `.titleTextColor`. Prefer `.vibrantColor` →
`.dominantColor` → first non-null among `.mutedColor /
.lightVibrantColor / .darkVibrantColor`. Size down the image before
extraction; full-res art is ~20× slower.

### Material 3 `ColorScheme.fromSeed`

- `WebFetch https://api.flutter.dev/flutter/material/ColorScheme/ColorScheme.fromSeed.html`
- `WebFetch https://m3.material.io/styles/color/the-color-system/color-roles`

**API summary reminder:** Slice 7 does **not** call `fromSeed` on
per-album palette — that would regenerate the 30-role Material
tokens every art swap. Instead, a fixed neutral `ColorScheme` drives
the app, and `AlbumPalette` is an additive `ThemeExtension` read
only by the two hero surfaces. `fromSeed` is still used once, at
app boot, to derive the neutral scheme from preset blue.

### Flutter `Hero` + `FlightShuttleBuilder`

- `WebFetch https://api.flutter.dev/flutter/widgets/Hero-class.html`
- `WebFetch https://api.flutter.dev/flutter/widgets/FlightShuttleBuilder.html`
- `WebFetch https://docs.flutter.dev/ui/widgets/hero`

**API summary reminder:** `Hero(tag: ..., child: ...)` on both
routes. Tag equality must be identity. `FlightShuttleBuilder` runs
during the flight; used here to interpolate art corner radius
(14 → 24 → 8 across the tile → detail → player layouts) and to
morph title text size between the detail header (28) and the
player header (20). Multiple concurrent heroes on the same route
require unique tags — three tags per album: art, title,
artist-chip.

### `ThemeExtension<T>`

- `WebFetch https://api.flutter.dev/flutter/material/ThemeExtension-class.html`
- `WebFetch https://api.flutter.dev/flutter/material/ThemeData/extensions.html`

**API summary reminder:** Subclass `ThemeExtension<T>`, override
`copyWith` and `lerp`. Registered via `ThemeData(extensions: [...])`
and read at consumers via `Theme.of(context).extension<T>()!`.
`lerp` matters for the palette — hero flight interpolates between
the neutral list palette and the art-derived detail palette.

### `google_fonts`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "google_fonts"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "GoogleFonts.inter asset bundling offline config"`.

**API summary reminder:** `google_fonts` defaults to runtime HTTP
fetch. Prism is offline-first, so slice 7 sets
`GoogleFonts.config.allowRuntimeFetching = false` at boot and ships
Inter (Regular/Medium/SemiBold/Bold) + Geist (Regular/Medium) as
bundled assets under `apps/mobile/assets/fonts/`. SF Pro is never
bundled (Apple EULA); its presence in the family list is a no-op
on Android/Linux.

## 5. Architecture & data flow

```
 MaterialApp.theme: ThemeData(
   colorScheme: ColorScheme.fromSeed(#6ba8ff),
   extensions: [ SpaceTokens.mobile(),        ← whole app
                 TypographyScale.prism(),     ← whole app
                 AlbumPalette.neutral() ],    ← replaced per-route below
   textTheme: typographyScale.toMaterialTextTheme(),
 )
 Only these two routes wrap in Theme(extensions:[AlbumPalette.fromArt]):
   AlbumDetailScreen, NowPlayingScreen.

 Album-art load → palette pipeline:

   Album route opened
          │
          ▼
   CachedNetworkImage (slice 2, url from metadata_cache)
          │ onLoaded(ImageProvider)
          ▼
   paletteFor(artKey)  ── DAO lookup ─► metadata_cache hit? ─yes─► tuple
          │ (miss)                                                 │
          ▼                                                        │
   compute(PaletteGenerator.fromImageProvider, sized 200×200)     │
          │                                                        │
          ▼                                                        │
   pickSwatches → (dominant, secondary, textOnDominant)           │
          │                                                        │
          ▼                                                        │
   chroma(dominant) < 0.15 ? ── yes ──► user-selected preset tuple │
          │                                                        │
          ▼                                                        │
   upsert metadata_cache(kind='palette', mbid=artKey, payload)    │
          │                                                        │
          └──────────────────────┬─────────────────────────────────┘
                                 ▼
                   AlbumPalette ThemeExtension (this route only)
                                 │
                                 ▼
              read by: Glass tint, Aurora accent blob, scrub-bar
              fill, play-button gradient. MiniPlayer stays neutral.
```

**Invariants**

- Palette extraction runs off the UI isolate via `compute()` — 200×200
  extraction takes 40–80 ms; on the isolate it never stutters the
  flight. The flight starts with the neutral palette; palette "pops"
  in when ready, lerped over 180 ms.
- Cache key is the exact art URL (hashed with SHA-1, 16 chars). Not
  the release MBID. Art URL can change when slice 2 upgrades the CAA
  redirect; keying on the URL makes the invalidation automatic.
- `AlbumPalette.neutral()` is the sentinel. Any route whose
  `Theme.of(context).extension<AlbumPalette>()` returns neutral
  renders without album tinting.

## 6. File layout (new files only)

```
/packages/ui/pubspec.yaml                               # pure Dart + flutter
/packages/ui/lib/ui.dart                                # barrel export
/packages/ui/lib/glass.dart                             # Glass widget
/packages/ui/lib/aurora_background.dart                 # AuroraBackground widget + AuroraVariant enum
/packages/ui/lib/typography.dart                        # TypographyScale ThemeExtension
/packages/ui/lib/space_tokens.dart                      # SpaceTokens ThemeExtension
/packages/ui/lib/palette.dart                           # AlbumPalette ThemeExtension + preset list + chroma test
/packages/ui/lib/hero_tags.dart                         # HeroTag static string builders
/packages/ui/test/space_tokens_test.dart                # lerp + constants
/packages/ui/test/typography_test.dart                  # resolved line-heights + sizes
/packages/ui/test/palette_test.dart                     # sparse-chroma fallback + lerp
/apps/mobile/lib/theme/prism_theme.dart                 # composes ThemeData with three extensions
/apps/mobile/lib/theme/palette_repository.dart          # extracts + caches album palettes
/apps/mobile/lib/theme/palette_providers.dart           # paletteForProvider(artKey)
/apps/mobile/lib/theme/settings_theme_section.dart      # Settings → Theme (preset picker)
/apps/mobile/assets/fonts/Inter-Regular.ttf             # + Medium/SemiBold/Bold
/apps/mobile/assets/fonts/Geist-Regular.ttf             # + Medium
/docs/plans/screenshots/album-detail.png                # reference (non-blocking)
/docs/plans/screenshots/now-playing.png                 # reference (non-blocking)
/docs/plans/screenshots/library.png                     # reference (non-blocking)
```

Slice 7 touches one `metadata_cache` schema boundary: it introduces a
new value for the `kind` column (`'palette'`). No DDL migration —
`kind` is already `TEXT NOT NULL` accepting any tag; slice 2's code
already ignores unknown `kind` values on read.

## 7. Interfaces & key types

```dart
// packages/ui/lib/space_tokens.dart
class SpaceTokens extends ThemeExtension<SpaceTokens> {
  final double s1, s2, s3, s4, s6, s8, s12;   // 4, 8, 12, 16, 24, 32, 48
  const SpaceTokens({...});
  const SpaceTokens.mobile()
    : s1 = 4, s2 = 8, s3 = 12, s4 = 16, s6 = 24, s8 = 32, s12 = 48;
  @override SpaceTokens lerp(other, double t);     // identity fast-path
}
```

A value of 16 is 16 everywhere; `lerp` returns `this` when `other`
is also `SpaceTokens.mobile()`.

```dart
// packages/ui/lib/typography.dart
class TypographyScale extends ThemeExtension<TypographyScale> {
  final TextStyle display36, display28, display20, body16, caption13;
  factory TypographyScale.prism();                // SF Pro → Inter → Geist
  TextTheme toMaterialTextTheme();                // → headline/body/label slots
  @override TypographyScale lerp(other, double t);
}
```

`TextStyle.height` baked in: 1.15 on the three displays, 1.45 on
body + caption. Letter-spacing: `-0.4` on `display36`, `-0.2` on
`display28`, `0` on `display20` and `body16`, `0.1` on `caption13`.

```dart
// packages/ui/lib/palette.dart
class AlbumPalette extends ThemeExtension<AlbumPalette> {
  final Color dominant;            // primary accent
  final Color secondary;           // aurora-blob / chip fill
  final Color textOnDominant;      // white or near-black, by luminance
  final AuroraVariant variant;     // which AuroraBackground layer
  final bool isNeutral;            // sentinel — no art / route excluded
  const AlbumPalette({...});
  const AlbumPalette.neutral();                    // preset blue, variant=home
  factory AlbumPalette.preset(PresetAccent p);     // 5 locked presets
  factory AlbumPalette.fromSwatches(PaletteGenerator g);
  @override AlbumPalette lerp(other, double t);    // channel-wise sRGB
}

enum PresetAccent { blue, pink, mint, amber, lilac }

const kPresetAccents = {
  PresetAccent.blue:  Color(0xFF6BA8FF),
  PresetAccent.pink:  Color(0xFFFFA0C8),
  PresetAccent.mint:  Color(0xFFA0E8C4),
  PresetAccent.amber: Color(0xFFFFC878),
  PresetAccent.lilac: Color(0xFFC0A0FF),
};
```

`lerp` on `isNeutral` uses the `t >= 0.5` convention — the flight
is ≤ 300 ms and the snap is invisible.

```dart
// packages/ui/lib/aurora_background.dart
enum AuroraVariant { home, album, player, library, ai }

class AuroraBackground extends StatelessWidget {
  final AuroraVariant variant;
  final Color? accentOverride;     // palette.dominant when present
  final Widget child;
}
```

Five variants embed base gradient + blob tuples matched 1:1 to the
JSX reference. `accentOverride` swaps the primary blob hue and the
base gradient's right-hand stop; `home`, `library`, `ai` ignore it.

```dart
// packages/ui/lib/glass.dart
enum GlassIntensity { light, medium, heavy }

class Glass extends StatelessWidget {
  final Widget child;
  final GlassIntensity intensity;
  final double radius;
  final EdgeInsetsGeometry? padding;
}
```

Uses `BackdropFilter(ImageFilter.blur + saturate-matrix)` with the
inset-1px + soft drop shadow combo from the JSX. On the Linux
software renderer it falls through to an opaque translucent fill —
one runtime check, no flag.

```dart
// packages/ui/lib/hero_tags.dart + palette_repository.dart
class HeroTags {
  static String art(String albumId)    => 'album.art:$albumId';
  static String title(String albumId)  => 'album.title:$albumId';
  static String artist(String albumId) => 'album.artist:$albumId';
}
abstract class PaletteRepository {
  Future<AlbumPalette> resolve(String artKey, ImageProvider image);
  Future<void> invalidate(String artKey);
}
```

`resolve`: (1) lookup `metadata_cache(kind='palette', mbid=artKey)`;
(2) on miss, `compute(_extract, image)`; (3) upsert and return. Art
URL change → new key → old row ages out under the 365-day TTL.

## 8. Implementation steps

Ordering is deliberate: typography + spacing are app-wide safe
changes; palette + hero are localized to two screens; Glass +
Aurora extraction is last so the primitives can be tuned against
the real theme before the `packages/ui` boundary locks them in.

1. **Add `packages/ui` to Melos.** Pubspec with Dart + `flutter` +
   `palette_generator`. Empty barrel. `melos bootstrap`.
   **Pass:** `melos list` prints the new package; path dep from
   `apps/mobile` resolves.

2. **Land SpaceTokens.** Write `space_tokens.dart` with the seven
   named fields, `.mobile()` factory, and `lerp`.
   **Pass:** `space_tokens_test.dart` asserts `s4 == 16` and lerp
   against itself returns `this`.

3. **Land TypographyScale.** Bundle four Inter weights + two Geist
   weights under `apps/mobile/assets/fonts/`; declare families in
   `pubspec.yaml`. Write `typography.dart` with the five `TextStyle`
   fields, `.prism()` factory, and `toMaterialTextTheme()` mapping
   to Material 3 slots (`displayLarge=display36`, `displayMedium=
   display28`, `headlineMedium=display20`, `bodyLarge=body16`,
   `labelSmall=caption13`).
   **Pass:** `typography_test.dart` — each style's `height` matches
   spec; `display36.fontSize == 36`.

4. **Compose `PrismTheme`.** `apps/mobile/lib/theme/prism_theme.dart`
   builds `ThemeData` from `ColorScheme.fromSeed(#6ba8ff)`, attaches
   the three extensions, sets `textTheme` from the typography scale.
   **Pass:** `app.dart` references `PrismTheme.light()`; `flutter
   analyze` clean.

5. **Migrate the app to tokens.** Sweep literal `EdgeInsets` and
   `TextStyle` in slice 1–6 screens; replace with token references.
   No visual diffs beyond the designed scale — review in pairs.
   **Pass:** `flutter analyze`, `melos run test` green; eyeball on
   Home, Library, Album detail, Now Playing, Queue, Settings.

6. **Land AlbumPalette.** Write `palette.dart` with the extension,
   five presets, `fromSwatches`, `chromaOf(Color)` (HSL-S ×
   luminance-weighted, threshold 0.15), `_pickSwatches` priority
   (`vibrantColor` → `dominantColor` → `mutedColor`), and `lerp`.
   **Pass:** `palette_test.dart` — a grayscale fixture falls to
   preset blue; a saturated one yields `isNeutral == false`.

7. **Write `PaletteRepository`.** Sqflite-backed; reuses
   `metadata_cache` via slice 2's `metadata_dao`. `resolve()`
   off-main-thread via `compute`. `paletteForProvider(artKey)` is a
   `FutureProvider.family` keyed by art URL hash.
   **Pass:** integration test — cold resolves <150 ms, warm <2 ms.

8. **Settings → Theme preset picker.** New section listing the
   five presets as swatches; radio-pick the default. Stored in
   `SharedPreferences` under `theme.defaultPreset`; read at boot.
   **Pass:** change preset → restart → neutral `AlbumPalette` uses
   new preset color; album-less surfaces reflect new accent.

9. **Wire `AlbumDetailScreen` palette override.** Watch
   `paletteForProvider(artKey)`. Wrap subtree in `Theme(data:
   Theme.of(context).copyWith(extensions: {..., AlbumPalette
   .fromSwatches(g)}), child:)`. Read the extension in `Glass` tint,
   scrub-bar fill, play-button gradient.
   **Pass:** load three albums of distinct tonality; detail accent
   clearly differs per album; grayscale-art album falls to preset.

10. **Wire `NowPlayingScreen` palette override.** Same approach,
    keyed by the currently-playing track's art URL. Aurora variant
    is `player`; `accentOverride` pipes `palette.dominant` into the
    blob hue. MiniPlayer stays neutral.
    **Pass:** pressing play from detail into Now Playing lerps the
    accent through the hero flight.

11. **Three hero tags on the three surfaces.** Tile → detail →
    player, all three tags (`art`, `title`, `artist`) on each. A
    `FlightShuttleBuilder` interpolates corner radius (14 → 24 → 8)
    and title font size (20 → 28 → 20).
    **Pass:** manual — album tile tap flies into detail; play tap
    flies into player; back reverses both without ghost frames.

12. **Extract `Glass`.** Port the JSX primitive (gradient surface,
    `BackdropFilter` blur + saturate, 1px inset, soft shadow).
    Three intensity settings map blur radii 14 / 24 / 40 and
    saturation 120% / 140% / 180%. Swap every inline frosted-box.
    **Pass:** visual parity with JSX on MiniPlayer, home
    "Can't decide?" row, detail tracklist wrapper.

13. **Extract `AuroraBackground`.** Port the five variants as Dart
    records of `(baseGradient, List<BlobSpec>)`. Wrap each top-level
    screen: Home=`home`, Library=`library`, Album detail=`album`,
    Now Playing=`player`, New Vibe sheet=`ai`, Queue/Settings=
    `library` (least-accented).
    **Pass:** side-by-side with JSX — each screen's backdrop hues
    match within ±5 LAB units.

14. **Capture reference screenshots.** On the Pixel 9 Pro Fold
    outer display. Commit Library, Album detail, Now Playing as
    PNGs under `docs/plans/screenshots/`. Non-blocking.
    **Pass:** three PNGs land in the repo.

15. **Run §11 verification.** **Pass:** every numbered item green.

## 9. Alternatives considered

**(a) Keep the app neutral everywhere.** `docs/spec.md` scope
calls out "Apple Music-inspired visual style […] adaptive
palette" — a neutral-everywhere app reads generic; album-derived
color is what makes a now-playing surface *feel* like this album
rather than that one. Rejected on scope. **Reconsider if:**
extraction proves unstable on pathological art and the chroma
gate cannot catch it.

**(b) Material You everywhere (`dynamic_color` + `fromSeed` per
album).** Regenerates all 30 Material color roles per album so
chips, cards, dividers drift with the art. `dynamic_color` pulls
the system accent on Android; on Linux it is a no-op. And it
tints the whole surface — the chromatic whiplash we specifically
want to avoid between Library (grid) and Album detail (hero).
Rejected on platform coverage and whiplash grounds. **Reconsider
if:** the product pivots to Android-only — not this release.

**(c) Adaptive palette on every screen, not just two.** Cleanest
in principle. In practice, Library (grid of 30) has no single
dominant; Random tab switches every refresh; Queue holds 10
arts at once. The two surfaces where a single album *is* the
subject — detail and player — are the only places the tint is
non-arbitrary. Rejected on "meaningless on multi-art surfaces".
**Reconsider if:** a later surface focuses on one album for
seconds at a time (e.g. a fullscreen Artist-of-the-Day card).

## 10. Edge cases & known risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Album art is gray / sepia / low-chroma; palette extraction returns a muddy brown. | `chromaOf(dominant)` < 0.15 → fall to user's selected preset tuple. Threshold tuned on the fixture set in `palette_test.dart`. |
| 2 | First paint on album detail blocks for synchronous palette compute. | Extraction runs via `compute()` off the UI isolate. First paint renders against `AlbumPalette.neutral()`; the palette arrives on a subsequent frame and lerps in over 180 ms. No blocking. |
| 3 | Hero tag collision if two albums share the same id. | `albumId` is `'${albumArtist ?? artist}∷${album}'` per slice 2 — collisions only occur for semantically-identical albums, which is the correct behavior (both tiles animate to the same destination). Documented here; no additional guard. |
| 4 | Palette cache stale when CAA re-redirects to a different image. | Cache key is the SHA-1 of the resolved art URL, not the release MBID. A new URL produces a new key; the old row ages out under the 365-day TTL. Settings → Clear metadata cache (slice 2) wipes palettes too. |
| 5 | `google_fonts` tries to hit the network in offline / airplane mode. | `GoogleFonts.config.allowRuntimeFetching = false` at boot; fonts resolve from bundled assets only. Adding an unbundled family would throw loudly in debug — intended. |
| 6 | `BackdropFilter` is prohibitively slow on the Linux software renderer (no GPU-accelerated blur). | `Glass` runtime-checks `defaultTargetPlatform == TargetPlatform.linux` plus `kIsWeb == false`; on the fallback path it renders an opaque 0.92-alpha fill with the same border/shadow, preserving legibility without blur cost. |
| 7 | Hero flight stutters because the shuttle builder allocates per frame. | `FlightShuttleBuilder` uses a `const` tween table and no object allocation inside `build`. Verified with DevTools timeline — flight holds 60 fps on the Pixel 9 Pro Fold outer display. |
| 8 | MiniPlayer is a global overlay, lives above both routes, and would be caught by the hero flight of the *album* and then disappear. | MiniPlayer art has its own untagged `Image`, not a `Hero`. No tag collision; no accidental flight hijack. |
| 9 | Palette extracted from a track whose art has not yet loaded (empty `ImageProvider`). | `resolve()` checks the provider via `resolve(ImageConfiguration.empty)` and bails to `AlbumPalette.neutral()` if the stream never completes within a 500 ms budget. Cache is not written. |
| 10 | Aurora grain `<svg>` data URL is large; embedding per-screen bloats memory. | One shared `AssetImage` under `packages/ui/assets/grain.png` (baked from the SVG), referenced by every `AuroraBackground`. Loaded once, cached by Flutter's image cache. |
| 11 | User rapidly taps between three albums; three palette extractions race. | `PaletteRepository.resolve` returns the same `Future` for concurrent calls on the same key (in-flight map). The two losers await the one winner. |
| 12 | Low-memory device evicts the palette cache row before it is read. | Misses are cheap — re-extract on next load. No correctness risk. |

## 11. Verification

Run in order. Screenshots from §8.14 linked below as reference
(not blocking). All items are executed on both Linux desktop and
the Pixel 9 Pro Fold.

1. `melos bootstrap` then `melos run test` passes across all five
   packages (slices 1, 2, + ui). New tests: `space_tokens_test`,
   `typography_test`, `palette_test`.
2. `flutter analyze` clean across `packages/ui` and `apps/mobile`.
3. Fonts: open every top-level screen; confirm headings render in
   Inter (verify via DevTools font inspector) with the expected
   weights. Body copy at 16 / 1.45; captions at 13 / 1.45.
4. Spacing: open Home, Library, Album detail, Now Playing, Queue;
   measure vertical rhythm with overlays — adjacent gaps resolve
   to `{4, 8, 12, 16, 24, 32, 48}` in every hit.
5. Hero: from Library → tap an album tile → art, title, and
   artist-chip fly into the detail. Tap play on a track → art and
   title fly into Now Playing (artist chip fades). Back button
   reverses each. Flight stays at ≥55 fps per DevTools.
6. Adaptive palette, distinct art: open three albums with
   visually-different covers (a blue-leaning rock record, a
   pink-leaning pop record, an amber-leaning jazz record). The
   Now Playing backdrop clearly differs per album within reason;
   each scrub-bar fill matches the art's dominant hue.
7. Adaptive palette, sparse-chroma art: pick an album with a
   near-grayscale cover (black-and-white photography, a grayscale
   minimalist sleeve). Detail and player surfaces fall to the
   user's selected preset — not a muddy mid-gray.
8. Preset pick: Settings → Theme → pick *pink*. Restart the app.
   A grayscale-art album now tints to `#ffa0c8`. Pick *mint*.
   Same album now tints to `#a0e8c4`. Pick back to *blue*.
9. Palette cache: open an album twice. Second open paints the
   accent on the first frame. Clear metadata cache from Settings.
   Open the same album; the first frame is neutral, the accent
   pops in on frame 2 or 3 (≤ 150 ms).
10. Aurora variant: each top-level screen's backdrop matches the
    reference PNG at `docs/plans/screenshots/` within ±5 LAB
    (spot check on Home, Library, Now Playing).
11. Typography vs Apple Music: on the three reference screens
    (Library grid, Album detail, Now Playing), display and body
    sizes match the Apple Music reference within ±1 px when
    measured by pixel ruler over a screenshot. The Apple Music
    reference lives under `docs/plans/screenshots/reference/`.
12. No regression: replay the slice 1 verification suite (play 10
    tracks, gapless, lockscreen controls, ReplayGain). All green;
    slice 7 is purely additive.
13. Offline: toggle airplane mode. All five top-level screens
    render type, glass, aurora, palette (from cache) with zero
    network traffic in `adb logcat | grep Dio`.
14. Metadata cache size: after loading ~200 albums, the
    `metadata_cache` rows of `kind='palette'` total ≤ 50 KB
    (payload is a 4-integer ARGB tuple + variant ordinal + flag).

## 12. Definition of done

- [ ] `packages/ui` exists, Dart + `flutter` + `palette_generator`;
  zero imports from `apps/mobile` or sibling packages.
- [ ] `SpaceTokens`, `TypographyScale`, `AlbumPalette` extend
  `ThemeExtension`, override `copyWith` and `lerp`, and land in
  `ThemeData.extensions`.
- [ ] `Glass` and `AuroraBackground` live in `packages/ui`; every
  inline frosted surface uses `Glass`; every top-level screen
  wraps in `AuroraBackground(variant: ...)`.
- [ ] Inter (4 weights) + Geist (2 weights) bundled;
  `GoogleFonts.config.allowRuntimeFetching == false` at boot; app
  opens in airplane mode with full typography.
- [ ] Five fallback presets land with **exact** locked values:
  `#6ba8ff`, `#ffa0c8`, `#a0e8c4`, `#ffc878`, `#c0a0ff`. Default
  default is blue.
- [ ] `PaletteRepository.resolve` caches `(dominant, secondary,
  textOnDominant, variant, isNeutral)` to `metadata_cache(kind=
  'palette')`; hit <2 ms, miss <150 ms off-isolate.
- [ ] `AlbumPalette` override applies **only** on
  `AlbumDetailScreen` and `NowPlayingScreen`; every other route
  reads `AlbumPalette.neutral()`.
- [ ] Three hero tags (`art`, `title`, `artist`) flow tile →
  detail → player without stutter on the Pixel 9 Pro Fold.
- [ ] Sparse-chroma art falls to the user-selected preset
  (verified against a grayscale fixture in `palette_test.dart`).
- [ ] `EdgeInsets` and `TextStyle` literals in slice 1–6 screens
  are replaced with token references.
- [ ] Slice 1 verification suite re-runs green; slice 7 is purely
  additive.
- [ ] Reference PNGs committed under `docs/plans/screenshots/`.
- [ ] `melos run test` and `flutter analyze` clean.
- [ ] §4 "Docs to refresh" executed; API-summary notes informed
  the palette-compute threading and `google_fonts` fetch decision.
- [ ] No deferred-work sentinels; unfinished UI ideas scoped out.
