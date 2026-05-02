/// Slim projection of `artist.getInfo`. Only the fields slice 2's
/// artist-detail screen renders.
class LastfmArtistInfo {
  final String mbid;
  final String name;

  /// Plaintext bio. Last.fm ships this with embedded HTML anchors —
  /// the rendering layer strips them; we keep the raw string so a
  /// future "open on last.fm" link can surface the linked entities.
  final String bio;
  final List<String> tags;

  const LastfmArtistInfo({
    required this.mbid,
    required this.name,
    required this.bio,
    required this.tags,
  });

  /// Parses the `artist` block of a `?method=artist.getinfo&format=json`
  /// response. Last.fm returns errors as `{ "error": 10, ... }` —
  /// callers check that envelope first and never invoke this on errors.
  factory LastfmArtistInfo.fromJson(Object? json) {
    final root = _asMap(json);
    final artist = _asMap(root['artist']);
    final bio = _asMap(artist['bio'])['content'];
    final tagBlock = _asMap(artist['tags']);
    final tags = _asList(tagBlock['tag'])
        .map((t) => _asString(_asMap(t)['name']))
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return LastfmArtistInfo(
      mbid: _asString(artist['mbid']) ?? '',
      name: _asString(artist['name']) ?? '',
      bio: _asString(bio) ?? '',
      tags: tags.length > 5 ? tags.sublist(0, 5) : tags,
    );
  }
}

Map<String, Object?> _asMap(Object? v) =>
    v is Map<String, Object?> ? v : (v is Map ? v.cast<String, Object?>() : {});

List<Object?> _asList(Object? v) =>
    v is List<Object?> ? v : (v is List ? v.cast<Object?>() : const []);
String? _asString(Object? v) => v is String ? v : null;
