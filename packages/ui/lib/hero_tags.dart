/// Hero tag builders for the album-tile → album-detail → now-playing
/// flight (slice 7 §7).
///
/// Three concurrent heroes per album surface — `art`, `title`, and
/// `artist` — so the [FlightShuttleBuilder] on the route push can
/// interpolate corner radius (14 → 24 → 8) and title font size
/// (20 → 28 → 20) on the art and title hero respectively, and fade
/// the artist chip independently.
///
/// Tag uniqueness is owned by the `albumId` argument. Slice 2's
/// `albumId` shape — `'${albumArtist ?? artist}∷${album}'` —
/// guarantees that two tiles tagged with the same id are
/// semantically the same album, which is the correct flight target
/// (slice 7 §10 risk 3).
class HeroTags {
  const HeroTags._();

  /// Album-art image hero. Used on the tile, the detail header,
  /// and the now-playing artwork.
  static String art(String albumId) => 'album.art:$albumId';

  /// Album-title text hero. Used on the detail header and the
  /// now-playing expanded title.
  static String title(String albumId) => 'album.title:$albumId';

  /// Artist-chip text hero. Used on the tile (subtitle), the
  /// detail header, and the now-playing artist line.
  static String artist(String albumId) => 'album.artist:$albumId';
}
