/// Minimal projection of `/ws/2/artist/{mbid}?inc=tags`.
///
/// Slice 2 only renders this when the user opens an artist-detail
/// screen for an artist whose MBID was resolved during recording
/// search. Tags arrive as the top N by `count`.
class MbArtist {
  final String mbid;
  final String name;
  final String? country;
  final String? type; // 'Person', 'Group', …
  final List<String> tags;

  const MbArtist({
    required this.mbid,
    required this.name,
    required this.tags,
    this.country,
    this.type,
  });

  factory MbArtist.fromJson(Object? json) {
    final map = _asMap(json);
    final tagList = _asList(map['tags'])
        .map((t) {
          final tm = _asMap(t);
          return _MbTag(
            name: _asString(tm['name']) ?? '',
            count: _asInt(tm['count']) ?? 0,
          );
        })
        .where((t) => t.name.isNotEmpty)
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return MbArtist(
      mbid: _asString(map['id']) ?? '',
      name: _asString(map['name']) ?? '',
      country: _asString(map['country']),
      type: _asString(map['type']),
      tags: tagList.take(5).map((t) => t.name).toList(growable: false),
    );
  }
}

class _MbTag {
  final String name;
  final int count;
  const _MbTag({required this.name, required this.count});
}

Map<String, Object?> _asMap(Object? v) =>
    v is Map<String, Object?> ? v : (v is Map ? v.cast<String, Object?>() : {});

List<Object?> _asList(Object? v) =>
    v is List<Object?> ? v : (v is List ? v.cast<Object?>() : const []);
String? _asString(Object? v) => v is String ? v : null;
int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v);
  if (v is num) return v.toInt();
  return null;
}
