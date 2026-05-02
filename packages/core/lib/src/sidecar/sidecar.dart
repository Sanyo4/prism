import 'package:json_annotation/json_annotation.dart';

import 'mood_vector.dart';

part 'sidecar.g.dart';

/// Schema version slice 4 understands. Bump on a breaking reader change
/// — e.g. removing a required field — and ship a `Migrations` bump in
/// the same commit so caches rebuild cleanly. Adding new optional
/// fields does **not** require a bump (forward-compat ignores them).
const int kCurrentSidecarSchemaVersion = 1;

/// Analyzer-model identifiers slice 4 considers fresh enough to ingest.
///
/// **Plan/spec deviation note:** the slice-4 plan §7 sketch listed
/// `'musicnn-msd-2'`, but slice 3 emits `'msd-musicnn-1'` (the actual
/// identifier in Essentia's upstream model registry — see
/// `apps/indexer/indexer/sidecar.py` for the matching deviation note).
/// Using the disk-actual identifier keeps ingest deterministic; a
/// future spec edit can rename without invalidating any sidecar.
const Set<String> kCompatibleAnalyzerModels = <String>{
  'msd-musicnn-1',
  'discogs-effnet-bs64-1',
};

/// One genre prediction from the discogs-effnet head: a `(label, score)`
/// pair. `genre_top3` always holds exactly three of these in descending
/// score order. Stored on disk as a JSON array of arrays
/// (`[["indie rock", 0.41], ...]`); we deserialise via [fromJson] / [toJson]
/// rather than `@JsonSerializable` because of the heterogeneous element
/// types — `json_serializable` doesn't have a clean shape for `[String, double]`.
class GenreTop {
  final String label;
  final double score;

  const GenreTop(this.label, this.score);

  factory GenreTop.fromJson(List<dynamic> json) {
    if (json.length != 2) {
      throw FormatException(
        'genre_top entry must be [label, score], got ${json.length} elements',
      );
    }
    return GenreTop(json[0] as String, (json[1] as num).toDouble());
  }

  List<dynamic> toJson() => <dynamic>[label, score];
}

/// In-memory representation of `<track>.sonic.json`. The on-disk shape
/// is locked by `docs/spec.md` and produced by slice 3's
/// `apps/indexer/indexer/sidecar.py`; this class is the read-side
/// mirror.
///
/// Validation is intentionally minimal — `SidecarReader` evaluates
/// staleness *before* trusting any value here. The constructor only
/// enforces invariants the spec calls out (`embedding` length 1280,
/// `genre_top3` length 3) so callers don't have to re-check.
@JsonSerializable(fieldRename: FieldRename.snake)
class Sidecar {
  /// Spec schema version. Slice-4 ingests only `kCurrentSidecarSchemaVersion`.
  final int schemaVersion;

  /// Analyzer identity, e.g. `"essentia-2.1-beta6-dev"`.
  final String analyzer;

  /// Models active when the sidecar was written. Compared against
  /// [kCompatibleAnalyzerModels] for the staleness check (disjoint =
  /// stale).
  final List<String> analyzerModels;

  /// SHA-1 of decoded PCM bytes (lowercase hex, 40 chars). The phone
  /// never recomputes this — desktop is authoritative.
  final String audioSha1;

  /// Audio duration in seconds, as measured by the analyzer (not from
  /// tags).
  final double durationSec;

  /// Output sample rate (Hz) the analyzer ran at.
  final int sampleRate;

  /// `null` for lossy sources where bit-depth is undefined.
  final int? bitDepth;

  /// Tempo estimate in beats per minute.
  final double bpm;

  /// Confidence in [bpm] (`0..1`).
  final double bpmConfidence;

  /// Detected key, e.g. `"Fm"`, `"C#"`, `"Bbm"`.
  final String key;

  /// Confidence in [key] (`0..1`).
  final double keyConfidence;

  /// Integrated loudness (LUFS).
  final double loudnessLufs;

  /// Measured ReplayGain (track) in dB. Slice 4's PlaybackService
  /// prefers this over tag-embedded RG when status='ready'.
  final double replaygainTrackDb;

  /// Measured ReplayGain (album) in dB. Currently equals
  /// [replaygainTrackDb] — slice-3 doesn't yet do album-level grouping.
  final double replaygainAlbumDb;

  /// Mean spectral centroid across the analysis window (Hz).
  final double spectralCentroidMean;

  /// Danceability (`0..1`) from Essentia's `Danceability` extractor.
  final double danceability;

  /// Five-dimensional mood vector.
  final MoodVector mood;

  /// Top-three genre predictions from the discogs-effnet head. Array
  /// of `[label, score]` arrays in descending score order.
  @JsonKey(name: 'genre_top3', fromJson: _genreTopListFromJson, toJson: _genreTopListToJson)
  final List<GenreTop> genreTop3;

  /// `1.0 == fully instrumental`; `0.0 == fully vocal`.
  final double voiceInstrumental;

  /// Always `"discogs-effnet-bs64-1"` for slice-3 sidecars.
  final String embeddingModel;

  /// Penultimate-layer embedding from the `embeddingModel` head.
  /// Length is exactly 1280 (constructor-enforced).
  final List<double> embedding;

  Sidecar({
    required this.schemaVersion,
    required this.analyzer,
    required this.analyzerModels,
    required this.audioSha1,
    required this.durationSec,
    required this.sampleRate,
    required this.bitDepth,
    required this.bpm,
    required this.bpmConfidence,
    required this.key,
    required this.keyConfidence,
    required this.loudnessLufs,
    required this.replaygainTrackDb,
    required this.replaygainAlbumDb,
    required this.spectralCentroidMean,
    required this.danceability,
    required this.mood,
    required this.genreTop3,
    required this.voiceInstrumental,
    required this.embeddingModel,
    required this.embedding,
  }) {
    if (embedding.length != 1280) {
      throw FormatException(
        'embedding must be length 1280, got ${embedding.length}',
      );
    }
    if (genreTop3.length != 3) {
      throw FormatException(
        'genre_top3 must have exactly 3 entries, got ${genreTop3.length}',
      );
    }
  }

  factory Sidecar.fromJson(Map<String, dynamic> json) =>
      _$SidecarFromJson(json);
  Map<String, dynamic> toJson() => _$SidecarToJson(this);

  static List<GenreTop> _genreTopListFromJson(List<dynamic> raw) =>
      raw.map((e) => GenreTop.fromJson(e as List<dynamic>)).toList();

  static List<List<dynamic>> _genreTopListToJson(List<GenreTop> v) =>
      v.map((g) => g.toJson()).toList();
}
