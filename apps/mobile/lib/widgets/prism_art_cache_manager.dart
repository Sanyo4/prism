import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Custom `flutter_cache_manager` for CAA artwork.
///
/// Two knobs slice 2 §1 calls out:
///  - **TTL: 60 days.** CAA images are nearly immutable but artists
///    occasionally re-upload a higher-res variant. 60 days is the
///    sweet spot between "always fresh" and "never re-fetch on a flaky
///    library that fingerprints differently".
///  - **LRU: 512 MB ≈ ~2,500 files.** `flutter_cache_manager` caps by
///    object count, not bytes. CAA front-500 thumbnails average
///    ~200 KB, so 2,500 lands at ~500 MB which is close enough to
///    the 512 MB target without a slice-2 byte-tracking layer.
///
/// Pinned by [_kCacheKey] which is *also* the on-disk subdirectory
/// name; pin lives here so the constant is greppable in one place.
class PrismArtCacheManager extends CacheManager {
  /// Subdirectory under the platform's cache root + the cache key
  /// the underlying SQLite info repo uses.
  static const String _kCacheKey = 'prismArt';

  static final PrismArtCacheManager _instance = PrismArtCacheManager._();

  factory PrismArtCacheManager() => _instance;

  PrismArtCacheManager._()
      : super(
          Config(
            _kCacheKey,
            stalePeriod: const Duration(days: 60),
            // 2,500 ≈ 512 MB at ~200 KB/file. Slice 7 polish can swap
            // to a byte-budgeted manager if real-world usage spills.
            maxNrOfCacheObjects: 2500,
          ),
        );
}
