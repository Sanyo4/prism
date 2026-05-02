/// Minimal projection of a MusicBrainz `/ws/2/release?query=...` hit.
///
/// Used as a fallback when `/recording?query=...` returns no high-score
/// match — typical for compilations whose recordings already exist in
/// MB but under different titles than the user's tags.
class MbRelease {
  final String mbid;
  final String title;
  final String? artistName;
  final String? artistMbid;
  final String? date;
  final String? country;
  final String? primaryType;
  final String? status;

  /// MusicBrainz "score" — 0..100. ≥ 80 is treated as a confident hit.
  final int score;

  const MbRelease({
    required this.mbid,
    required this.title,
    required this.score,
    this.artistName,
    this.artistMbid,
    this.date,
    this.country,
    this.primaryType,
    this.status,
  });

  factory MbRelease.fromJson(Object? json) {
    final map = _asMap(json);
    final ac = _asList(map['artist-credit']);
    final firstAc = ac.isEmpty ? const <String, Object?>{} : _asMap(ac.first);
    final firstArtist = _asMapOrNull(firstAc['artist']);
    return MbRelease(
      mbid: _asString(map['id']) ?? '',
      title: _asString(map['title']) ?? '',
      score: _asInt(map['score']) ?? 0,
      artistName: _asString(firstArtist?['name']) ?? _asString(firstAc['name']),
      artistMbid: _asString(firstArtist?['id']),
      date: _asString(map['date']),
      country: _asString(map['country']),
      primaryType:
          _asString(_asMapOrNull(map['release-group'])?['primary-type']),
      status: _asString(map['status']),
    );
  }

  int? get year {
    final d = date;
    if (d == null || d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }
}

Map<String, Object?> _asMap(Object? v) =>
    v is Map<String, Object?> ? v : (v is Map ? v.cast<String, Object?>() : {});
Map<String, Object?>? _asMapOrNull(Object? v) {
  if (v == null) return null;
  return v is Map<String, Object?> ? v : (v as Map).cast<String, Object?>();
}

List<Object?> _asList(Object? v) =>
    v is List<Object?> ? v : (v is List ? v.cast<Object?>() : const []);
String? _asString(Object? v) => v is String ? v : null;
int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v);
  if (v is num) return v.toInt();
  return null;
}
