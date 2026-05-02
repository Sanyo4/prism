/// Minimal projection of a MusicBrainz `/ws/2/recording?query=...` hit.
///
/// We only parse the fields the backfill actually uses; the raw payload
/// is cached upstream so a future slice can extract more without a
/// re-fetch. Confidence is the upstream `score` (0–100) — the
/// repository drops anything below 80.
class MbRecording {
  final String mbid;
  final String title;
  final String? artistName;
  final String? artistMbid;

  /// Releases the recording appears on. The backfill picks the first
  /// release whose `status == 'Official'`, falling back to the first
  /// entry when none match.
  final List<MbRecordingRelease> releases;

  /// MusicBrainz "score" — 0..100. We treat ≥ 80 as good enough.
  final int score;

  const MbRecording({
    required this.mbid,
    required this.title,
    required this.score,
    required this.releases,
    this.artistName,
    this.artistMbid,
  });

  /// Parses one entry of `recordings[]` from a `/recording?query=...`
  /// response. Wraps `Object?` rather than `Map<String, dynamic>` to
  /// keep the analyzer's `strict-casts` happy across mixed types.
  factory MbRecording.fromJson(Object? json) {
    final map = _asMap(json);
    final ac = _asList(map['artist-credit']);
    final firstAc = ac.isEmpty ? const <String, Object?>{} : _asMap(ac.first);
    final firstArtist = _asMapOrNull(firstAc['artist']);
    return MbRecording(
      mbid: _asString(map['id']) ?? '',
      title: _asString(map['title']) ?? '',
      // `score` is a stringified int in some response shapes (search) and
      // a real int in others (browse). Accept both.
      score: _asInt(map['score']) ?? 0,
      artistName: _asString(firstArtist?['name']) ?? _asString(firstAc['name']),
      artistMbid: _asString(firstArtist?['id']),
      releases: _asList(map['releases'])
          .map((r) => MbRecordingRelease.fromJson(r))
          .toList(growable: false),
    );
  }
}

/// One entry in `recording.releases[]`. The MB response mixes release
/// metadata (id, title, date, status) with a `release-group` block
/// that carries `primary-type` (Album / Single / EP …).
class MbRecordingRelease {
  final String mbid;
  final String? title;
  final String? status; // 'Official', 'Promotion', 'Bootleg', or null
  final String? date; // 'YYYY-MM-DD', 'YYYY-MM', 'YYYY', or null
  final String? primaryType; // 'Album', 'Single', 'EP', …
  final int? trackNo;
  final int? discNo;
  final String? country;

  const MbRecordingRelease({
    required this.mbid,
    this.title,
    this.status,
    this.date,
    this.primaryType,
    this.trackNo,
    this.discNo,
    this.country,
  });

  factory MbRecordingRelease.fromJson(Object? json) {
    final map = _asMap(json);
    // MB nests track/disc numbers inside media[0].track[0].
    final media = _asList(map['media']);
    int? trackNo, discNo;
    if (media.isNotEmpty) {
      final m = _asMap(media.first);
      discNo = _asInt(m['position']);
      final tracks = _asList(m['track']);
      if (tracks.isNotEmpty) {
        trackNo = _asInt(_asMap(tracks.first)['number']) ??
            _asInt(_asMap(tracks.first)['position']);
      }
    }
    return MbRecordingRelease(
      mbid: _asString(map['id']) ?? '',
      title: _asString(map['title']),
      status: _asString(map['status']),
      date: _asString(map['date']),
      primaryType:
          _asString(_asMapOrNull(map['release-group'])?['primary-type']),
      country: _asString(map['country']),
      trackNo: trackNo,
      discNo: discNo,
    );
  }

  /// Year extracted from the partial-date string. `null` when the
  /// release has no date or the prefix is not 4 digits.
  int? get year {
    final d = date;
    if (d == null || d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }
}

// ---------------------------------------------------------------------------
// Internal shared parse helpers. Kept private to this file so they can be
// duplicated in `mb_release.dart` etc. without leaking into the package
// surface — the alternative (a shared `_parse_helpers.dart`) would force
// a `part`/`part of` directive that the analyzer's strict-casts disliked
// in earlier exploration.
// ---------------------------------------------------------------------------

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
