/// Prism UI primitives — typography, spacing, album palette,
/// frosted Glass, and AuroraBackground variants.
///
/// Track A of slice 7 owns this package. Track B (theme composition,
/// hero wiring, palette repository, mobile-app token sweep) imports
/// the entire surface as `import 'package:prism_ui/ui.dart';`.
///
/// See `docs/plans/slice-07-apple-music-polish.md` §6 / §7 for the
/// authoritative interfaces.
library;

export 'aurora_background.dart';
export 'glass.dart';
export 'hero_tags.dart';
export 'palette.dart';
export 'space_tokens.dart';
export 'typography.dart';
