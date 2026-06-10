import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:prism_metadata/metadata.dart';
import 'package:prism_ui/ui.dart';

/// Read+write side of the slice-7 album-palette cache.
///
/// Storage: `metadata_cache(kind='palette', mbid=artKey, payload=json)`.
/// `artKey` is `sha1(artUrl).hex.substring(0, 16)`; the slice-2 metadata
/// DB is reused, no DDL migration (slice 7 §6 / §10 risk 4).
///
/// Concurrency: rapid taps on three different albums shouldn't race
/// three palette extractions for the same key. The in-flight map dedupes
/// concurrent calls — the two losers await the winner's future
/// (slice 7 §10 risk 11).
abstract class PaletteRepository {
  /// Resolves the palette for [artKey].
  ///
  /// (1) cache lookup → return decoded payload if present.
  /// (2) miss → wait up to 500 ms for [image] to load, run
  ///     [PaletteGenerator.fromImageProvider] (which off-loads to a
  ///     worker isolate), build [AlbumPalette] via
  ///     [AlbumPalette.fromSwatches] with [fallback] as the
  ///     sparse-chroma punt.
  /// (3) on success, upsert into `metadata_cache` with a 365-day TTL.
  Future<AlbumPalette> resolve(
    String artKey,
    ImageProvider image,
    PresetAccent fallback,
  );

  /// Removes the cached palette for [artKey]. Slice 2's "Clear metadata
  /// cache" wipes everything; this single-row delete is for slice 7's
  /// per-album invalidation paths (e.g. CAA URL drift, slice 7 §10
  /// risk 4).
  Future<void> invalidate(String artKey);

  /// Returns the SHA-1-hashed cache key for [url]. Stable across runs.
  String artKeyFor(String url);
}

/// Production [PaletteRepository] backed by [MetadataDao] +
/// [PaletteGenerator].
class PaletteRepositoryImpl implements PaletteRepository {
  PaletteRepositoryImpl(this._dao);

  final MetadataDao _dao;

  /// In-flight map for concurrent-resolve dedup (slice 7 §10 risk 11).
  /// Keyed by `artKey`; the entry self-clears on completion regardless
  /// of error.
  final Map<String, Future<AlbumPalette>> _inFlight = {};

  @override
  Future<AlbumPalette> resolve(
    String artKey,
    ImageProvider image,
    PresetAccent fallback,
  ) {
    final existing = _inFlight[artKey];
    if (existing != null) return existing;
    final future = _resolveImpl(artKey, image, fallback);
    _inFlight[artKey] = future;
    future.whenComplete(() => _inFlight.remove(artKey));
    return future;
  }

  Future<AlbumPalette> _resolveImpl(
    String key,
    ImageProvider image,
    PresetAccent fallback,
  ) async {
    final hit = await _dao.readCache('palette', key);
    if (hit != null) {
      try {
        return _decode(hit.payload);
      } catch (_) {
        // Malformed payload — treat as a miss and re-extract. The
        // upsert below will overwrite the bad row.
      }
    }
    final palette = await _extract(image, fallback);
    if (!palette.isNeutral || _shouldCacheNeutral(image)) {
      await _dao.upsertCache(
        kind: 'palette',
        mbid: key,
        payload: _encode(palette),
        ttl: CacheTtl.oneYear,
      );
    }
    return palette;
  }

  Future<AlbumPalette> _extract(
    ImageProvider image,
    PresetAccent fallback,
  ) async {
    // Bail on unloaded images per §10 risk 9 — 500 ms budget. We never
    // cache a "image didn't load" outcome so a flaky network can self-
    // heal on next open.
    final ready = await _waitForImage(
      image,
      const Duration(milliseconds: 500),
    );
    if (!ready) return AlbumPalette.preset(fallback);
    // PaletteGenerator does its own off-main work via an isolate-side
    // histogram; an extra `compute()` round-trip would have to ship the
    // ImageProvider (not isolate-safe) and would add latency without
    // moving the heavy CPU off of where it already runs. Inline.
    final generator = await PaletteGenerator.fromImageProvider(
      image,
      size: const Size(200, 200),
      maximumColorCount: 16,
    );
    return AlbumPalette.fromSwatches(generator, fallback: fallback);
  }

  /// Resolves the [provider] image stream and waits for its first
  /// frame, with a [timeout]. Returns true when a frame arrives,
  /// false on timeout or error. Removes the listener regardless.
  Future<bool> _waitForImage(
    ImageProvider provider,
    Duration timeout,
  ) {
    final completer = Completer<bool>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(true);
        stream.removeListener(listener);
      },
      onError: (Object e, StackTrace? st) {
        if (!completer.isCompleted) completer.complete(false);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future
        .timeout(timeout, onTimeout: () => false);
  }

  /// We deliberately *don't* cache neutral results here — the next
  /// open of the same album can retry extraction without reading a
  /// stale "the image timed out once" entry. Hook left in place so
  /// a future tuning pass can flip the policy.
  bool _shouldCacheNeutral(ImageProvider image) => false;

  String _encode(AlbumPalette p) {
    return jsonEncode(<String, Object?>{
      'dominant': _argbValue(p.dominant),
      'secondary': _argbValue(p.secondary),
      'textOnDominant': _argbValue(p.textOnDominant),
      'variant': p.variant.name,
      'isNeutral': p.isNeutral,
    });
  }

  AlbumPalette _decode(String payload) {
    final j = jsonDecode(payload) as Map<String, Object?>;
    return AlbumPalette(
      dominant: Color(j['dominant'] as int),
      secondary: Color(j['secondary'] as int),
      textOnDominant: Color(j['textOnDominant'] as int),
      variant: AuroraVariant.values.byName(j['variant'] as String),
      isNeutral: j['isNeutral'] as bool,
    );
  }

  /// Pack a [Color] into an ARGB32 int the same way `Color.value` did
  /// before it was deprecated in Flutter 3.27. Round-tripped through
  /// the integer payload field of `metadata_cache`.
  int _argbValue(Color c) {
    final a = (c.a * 255).round() & 0xFF;
    final r = (c.r * 255).round() & 0xFF;
    final g = (c.g * 255).round() & 0xFF;
    final b = (c.b * 255).round() & 0xFF;
    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  @override
  String artKeyFor(String url) {
    final digest = sha1.convert(utf8.encode(url));
    return digest.toString().substring(0, 16);
  }

  @override
  Future<void> invalidate(String artKey) {
    return _dao.deleteCache('palette', artKey);
  }
}
