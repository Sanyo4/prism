/// Result of a Cover Art Archive front-image lookup.
///
/// CAA's `/release/{mbid}/front-500` returns:
///   - 307 → image at archive.org (we don't follow; the image URL is
///     stable and `cached_network_image` will follow when it loads)
///   - 404 → no front art for the release (cache the miss)
///   - other → unknown failure (caller persists `last_error`)
///
/// We expose the *original* CAA URL, not the redirect target, because
/// the redirect path is unstable across CAA mirror moves.
class CaaArt {
  /// `https://coverartarchive.org/release/{mbid}/front-500` — caller
  /// hands this to `CachedNetworkImage(imageUrl:, cacheKey: mbid, ...)`.
  final String url;

  /// Release MBID — mirror of the lookup key. Used as the
  /// `cacheKey` so URL variants don't re-download.
  final String releaseMbid;

  const CaaArt({required this.url, required this.releaseMbid});
}
