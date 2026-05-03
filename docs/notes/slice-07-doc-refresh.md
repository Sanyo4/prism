# Slice 7 — doc refresh

> Track A (packages/ui) author of this file. Track B should append.

## Reference availability

The actual design bundle landed at `/tmp/prism-design-extract/music/`
(not `/tmp/design-extract/`, which the original brief sketched).
Bundle structure:

```
music/
├── README.md                     # design handoff README
├── chats/chat1.md                # user/assistant transcript
└── project/
    ├── Prism Music Player.html   # entry point (the user had this open)
    ├── data/library.jsx          # fictional artist/album fixtures
    ├── frames/                   # android-frame.jsx, design-canvas.jsx
    ├── screens/                  # mobile-{shell,browse,detail}.jsx, desktop.jsx
    ├── ui/primitives.jsx         # Glass, AeroSlider, ChromeButton, AlbumArt, ArtistAvatar, Icon
    └── uploads/                  # screenshots
```

**`Glass` matches §7 verbatim** — slice plan transcribed the JSX
spec accurately. Three intensity levels map blur 14/24/40 and
saturate 140/180% (light/medium/heavy). The `linear-gradient(160deg,
rgba(255,255,255,0.55) 0%, rgba(255,255,255,0.32) 60%,
rgba(255,255,255,0.22) 100%)` surface gradient + the four-shadow
inner decoration (inset 0 1px 0 rgba(255,255,255,0.95) etc.) are
preserved in Track A's port.

**`AuroraBackground` matches §7 verbatim** — slice plan transcribed
the JSX `AuroraBg` spec accurately. The five variants (`home`,
`album`, `player`, `library`, `ai`) match `screens/mobile-shell.jsx`
lines 7-74 exactly: same base gradients, same 2-3 radial blobs per
variant, same grain noise overlay (0.12 opacity, mix-blend-mode:
overlay in the JSX → 0.04 via Flutter Image overlay in our port).

**Typography deviation: Space Grotesk** — design uses `"Space
Grotesk", system-ui, sans-serif` everywhere (`primitives.jsx:47-48`,
`mobile-shell.jsx:86`). Slice-7 plan listed SF Pro / Inter / Geist;
we deviate to match the design. `TypographyScale.prism()` calls
`GoogleFonts.spaceGrotesk(...)` per style; `main.dart` enables
runtime fetching so the cache populates on first launch. Slice 8
can bundle the TTFs for true offline-from-cold-install.

**Out-of-scope-for-7 design elements** flagged for later slices:
- `AeroSlider` and `ChromeButton` first-class primitives
  (currently in-app Material wrappers per slice-7 §2 non-goal).
- Generative `AlbumArt` (3-color radial-gradient bloom from
  `album.color1/color2/color3`).
- 4-tab bottom nav `Home / Search / Library / Create` — current
  app has Tracks/NowPlaying/Queue/AI from slices 1+6; "Search"
  has no underlying functionality in any slice.
- Tweaks toolbar: density and blur-intensity sliders.

## palette_generator (Context7 + pub.dev)

API — confirmed against pub.dev/documentation as of slice 7 build:

```dart
static Future<PaletteGenerator> PaletteGenerator.fromImageProvider(
  ImageProvider<Object> imageProvider, {
  Size? size,
  Rect? region,
  int maximumColorCount,
  List<PaletteFilter> filters,
  List<PaletteTarget> targets,
  Duration timeout,
});
```

- All swatch getters (`vibrantColor`, `dominantColor`, `mutedColor`,
  `lightVibrantColor`, `darkVibrantColor`, `lightMutedColor`,
  `darkMutedColor`) return `PaletteColor?` — nullable.
- Each `PaletteColor` exposes `.color`, `.bodyTextColor`,
  `.titleTextColor`, plus `.population`.
- For unit tests, use the named constructor
  `PaletteGenerator.fromColors(List<PaletteColor> paletteColors)`.
  This sidesteps image decoding entirely.
- Pick priority used by `AlbumPalette.fromSwatches`:
  `vibrantColor → dominantColor → mutedColor → lightVibrantColor →
  darkVibrantColor`. First non-null wins; chroma gate at 0.15 then
  vetoes muddy picks back to the preset.
- Threading: extraction at 200×200 takes ~40-80 ms; consumer
  (Track B's `PaletteRepository`) runs it via `compute()`.

## google_fonts (Context7 + pub.dev)

- Default behaviour: HTTP fetch on first use, cached in app
  documents. Prism is offline-first, so app boot must set
  `GoogleFonts.config.allowRuntimeFetching = false` (Track B owns
  this flag at boot; Track A's `TypographyScale.prism()` references
  the `interTextTheme()` which respects the flag).
- Bundled-asset path: drop `Inter-Regular.ttf`, `Inter-Medium.ttf`,
  `Inter-SemiBold.ttf`, `Inter-Bold.ttf` (and Geist Regular/Medium)
  under `apps/mobile/assets/fonts/` — Track B's scope. Pubspec lists
  the directory; `google_fonts` auto-detects matching weights and
  prefers the local file. Family names match the Google Fonts
  display name (`Inter`, `Geist`).
- SF Pro Display is **never** bundled (Apple EULA). It appears as
  the *primary* family in `TypographyScale.prism()`'s `fontFamily`
  hint with `fontFamilyFallback: ['Inter', 'Geist']`. On Apple
  devices the system shell resolves SF Pro; on Android/Linux the
  family resolves to Inter without an error.
- Filename → `FontWeight` mapping used by the asset-detection
  pipeline: w100=Thin, w200=ExtraLight, w300=Light, w400=Regular,
  w500=Medium, w600=SemiBold, w700=Bold, w800=ExtraBold,
  w900=Black.

## ThemeExtension (api.flutter.dev)

Required overrides on `class T extends ThemeExtension<T>`:

```dart
@override ThemeExtension<T> copyWith({...});  // no-arg signature
@override ThemeExtension<T> lerp(
  covariant ThemeExtension<T>? other,
  double t,
);
```

- `copyWith` returns a `ThemeExtension<T>` (in practice we tighten
  the return type to `T` via covariance; that's what slice 7's
  three extensions all do).
- `lerp` accepts a nullable `other`. If `other is! T`, returning
  `this` is the canonical fallback. Track A's three extensions all
  follow that pattern.
- Materialised in `ThemeData(extensions: [SpaceTokens.mobile(),
  TypographyScale.prism(), AlbumPalette.neutral()])` — Track B
  owns the composition.

## ColorScheme.fromSeed (informational — Track B's call site)

Track A does not reference `ColorScheme.fromSeed`. Notes for Track
B's `prism_theme.dart`:

```dart
ColorScheme.fromSeed({
  required Color seedColor,
  Brightness brightness = Brightness.light,
  DynamicSchemeVariant dynamicSchemeVariant =
      DynamicSchemeVariant.tonalSpot,
  double contrastLevel = 0.0,
  // ... 47 optional Color overrides
});
```

Slice 7 calls it once at boot with `Color(0xFF6BA8FF)` — preset
blue — and never per-album. Per-album tinting is the
`AlbumPalette` `ThemeExtension` instead, applied to two routes
only.

---

## Track B — appended notes

> Track A scope above; Track B owns the apps/mobile theme,
> palette repository, hero wiring, and the mobile token sweep.

### Hero (api.flutter.dev)

```dart
const Hero({
  required Object tag,
  CreateRectTween? createRectTween,
  HeroFlightShuttleBuilder? flightShuttleBuilder,
  HeroPlaceholderBuilder? placeholderBuilder,
  bool transitionOnUserGestures = false,
  required Widget child,
});
```

- Tag identity is by `==` — Slice 7 uses a string built by
  `HeroTags.{art,title,artist}(albumId)` so the tile, detail, and
  player share a single tag per channel.
- Three concurrent heroes per album are legal as long as each tag
  is unique on both source and destination — that's why slice 7
  ships three tag builders rather than one.
- `flightShuttleBuilder` runs **only during the flight**, so any
  morphing (corner radius 14 → 24 → 8 on art, title size 20 → 28
  → 20) lives in the shuttle, not in the source/destination
  widgets themselves.

### FlightShuttleBuilder (api.flutter.dev)

```dart
typedef HeroFlightShuttleBuilder = Widget Function(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
);
```

- `animation` ranges 0 → 1 across the flight; we drive
  interpolation with `Tween<double>().evaluate(animation)` rather
  than reading the value imperatively to avoid per-frame allocation
  (slice 7 §10 risk 7).
- Flight direction (`push` vs `pop`) is captured in
  `flightDirection`. We use the same shuttle builder for both
  legs — the tween reverses naturally.
- The shuttle's parent during the flight is the route transition
  Overlay, not the source / destination route, so any `Theme`-
  derived reads inside the shuttle should pull from
  `flightContext`, not `from`/`toHeroContext`.

### palette_generator threading

- `PaletteGenerator.fromImageProvider` already runs the
  histogram + clustering on a worker isolate internally, so
  `compute()` would round-trip the `ImageProvider` (not
  isolate-safe). Track B's `PaletteRepository` therefore awaits
  the future inline; the package handles the off-main work.
- 500 ms image-load timeout (slice 7 §10 risk 9): we resolve the
  `ImageStream`, listen for the first frame, and bail to neutral
  on timeout / error without writing to cache.

### `metadata_cache` palette rows

Slice 7 §6 — `kind = 'palette'`, `mbid = sha1(artUrl).hex.16`.
Payload schema (JSON):

```json
{
  "dominant": 0xFF112233,
  "secondary": 0xFF445566,
  "textOnDominant": 0xFFFFFFFF,
  "variant": "album",
  "isNeutral": false
}
```

TTL: 365 days (slice 7 §6 / §10 risk 4).
