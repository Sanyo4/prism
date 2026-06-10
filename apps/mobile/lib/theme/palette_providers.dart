import 'dart:io' show Platform;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prism_metadata/metadata.dart';
import 'package:prism_ui/ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import '../widgets/prism_art_cache_manager.dart';
import 'palette_repository.dart';

/// SharedPreferences key for the user-selected default preset accent.
/// Read at boot, written from the Settings → Theme picker.
const _kThemePresetPrefKey = 'theme.defaultPreset';

/// One-shot per-process [PaletteRepository] over `metadata_cache`.
///
/// Opens its own sqflite handle on the slice-2 `prism.db` file so the
/// existing slice-2 [metadataRepositoryProvider]'s lifecycle (which is
/// keyed on `onlineMetadataSettingsProvider`) doesn't churn the palette
/// store on every settings flip. WAL mode (set by slice-2's open path)
/// makes a second handle on the same file safe.
final paletteRepositoryProvider =
    FutureProvider<PaletteRepository>((ref) async {
  final factory = await _resolveFactory();
  final supportDir = await getApplicationSupportDirectory();
  final dbPath = p.join(supportDir.path, 'prism.db');
  // Same DDL as MetadataDb — calling `open` is idempotent because
  // sqflite's `onCreate` only fires when the file is new.
  final db = await MetadataDb.open(factory: factory, path: dbPath);
  ref.onDispose(db.close);
  final dao = MetadataDao(db);
  return PaletteRepositoryImpl(dao);
});

/// Per-art-key palette resolver. Keyed by `artKey` (16-char SHA-1
/// prefix of the art URL — see [PaletteRepository.artKeyFor]).
///
/// Family arg is the [PaletteForKey] tuple `(artKey, artUrl)` — the URL
/// is needed to construct the [CachedNetworkImage] image provider on a
/// cache miss; the key is used as the DB row id (slice 7 §6).
final paletteForProvider =
    FutureProvider.family<AlbumPalette, PaletteForKey>(
  (ref, args) async {
    final repo = await ref.watch(paletteRepositoryProvider.future);
    final preset = ref.watch(themePresetProvider);
    // Construct the image provider on demand so the resolver can
    // wait for its first frame — and so the same disk cache as the
    // album-tile / detail-hero render is reused.
    final image = CachedNetworkImageProvider(
      args.artUrl,
      cacheKey: args.cacheKey,
      cacheManager: PrismArtCacheManager(),
    );
    return repo.resolve(args.artKey, image, preset);
  },
);

/// Family argument for [paletteForProvider]. We pass the URL plus a
/// stable cache key so the underlying [CachedNetworkImage] disk lookup
/// hits the same bucket as the visible album tile (slice 2's
/// `cacheKey: album.releaseMbid`).
@immutable
class PaletteForKey {
  const PaletteForKey({
    required this.artKey,
    required this.artUrl,
    required this.cacheKey,
  });

  /// 16-char SHA-1 prefix of [artUrl].
  final String artKey;

  /// The full art URL — used as the [ImageProvider] source on a
  /// cache miss.
  final String artUrl;

  /// `cacheKey` to hand to [CachedNetworkImageProvider] so the disk
  /// bucket matches the visible album surface.
  final String? cacheKey;

  @override
  bool operator ==(Object other) =>
      other is PaletteForKey && other.artKey == artKey;

  @override
  int get hashCode => artKey.hashCode;
}

/// User's default preset accent. Persisted in SharedPreferences under
/// `theme.defaultPreset`; loaded asynchronously at startup. The initial
/// state is [PresetAccent.blue] (slice 7 §2 / §8 step 8 default-default).
final themePresetProvider =
    NotifierProvider<ThemePresetNotifier, PresetAccent>(
  ThemePresetNotifier.new,
);

class ThemePresetNotifier extends Notifier<PresetAccent> {
  SharedPreferences? _prefs;

  @override
  PresetAccent build() {
    // Async hydration — initial render uses preset blue (the default)
    // until prefs resolve. Subsequent rebuilds (after `_publish`) lift
    // the user's choice into state.
    Future<void>(() async {
      _prefs = await SharedPreferences.getInstance();
      _publish();
    });
    return PresetAccent.blue;
  }

  void _publish() {
    final prefs = _prefs;
    if (prefs == null) return;
    final raw = prefs.getString(_kThemePresetPrefKey);
    if (raw == null) return;
    final match = PresetAccent.values
        .where((p) => p.name == raw)
        .firstOrNull;
    if (match != null) state = match;
  }

  /// Persists [preset] and updates state. The Settings → Theme picker
  /// awaits this so the picker doesn't dismiss before the write
  /// completes.
  Future<void> setPreset(PresetAccent preset) async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(_kThemePresetPrefKey, preset.name);
    state = preset;
  }
}

extension _FirstOrNullExt<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}

Future<DatabaseFactory> _resolveFactory() async {
  if (Platform.isAndroid) {
    return sqflite.databaseFactory;
  }
  ffi.sqfliteFfiInit();
  return ffi.databaseFactoryFfi;
}
