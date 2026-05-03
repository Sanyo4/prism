import 'package:meta/meta.dart';

import 'llm_backend.dart' show LlmJsonParseException;
import 'prompts/mood_lookup.dart';

/// Direction the energy of the playlist should follow over its 12
/// picks. `flat` keeps tempo/intensity steady; `build` ramps up;
/// `descend` ramps down; `wave` alternates. Maps to a pseudo-
/// `RadioSession` chip set in the flow step.
enum EnergyArc { build, wave, flat, descend }

/// Candidate pool relaxation (slice plan §10 risk 5). `strict` is
/// the LLM's literal intent; `loose` widens BPM ±10 and drops era;
/// `veryLoose` keeps only the primary mood clause and doubles the
/// `LIMIT`. Repos surface this via `candidatePoolByIntent`.
enum RelaxationLevel { strict, loose, veryLoose }

/// One mood constraint. `mood` is one of the 5 classifier moods
/// (`happy`, `sad`, `aggressive`, `relaxed`, `party`). `min` is the
/// lower bound (`>=0.5`) and `max` the upper (`<=0.3`); both
/// optional.
@immutable
class MoodTarget {
  /// One of `happy`, `sad`, `aggressive`, `relaxed`, `party`.
  final String mood;
  final double? min;
  final double? max;

  const MoodTarget({required this.mood, this.min, this.max});

  /// Parses one element of the `mood_targets` array. Snaps the
  /// `mood` field through [MoodLookup.snap] so unknown adjectives
  /// (e.g. `"melancholic"`) collapse into the 5-enum vocabulary.
  /// Throws [LlmJsonParseException] when [j] is not an object or
  /// the `mood` key is missing/non-string.
  factory MoodTarget.fromJson(Object? j) {
    if (j is! Map<String, dynamic>) {
      throw LlmJsonParseException(
        'mood_targets[]: expected object, got ${j.runtimeType}',
      );
    }
    final raw = j['mood'];
    if (raw is! String || raw.trim().isEmpty) {
      throw LlmJsonParseException(
        'mood_targets[].mood: missing or non-string',
      );
    }
    final snapped = MoodLookup.snap(raw);
    final min = _parseUnit(j['min'], 'min');
    final max = _parseUnit(j['max'], 'max');
    return MoodTarget(mood: snapped, min: min, max: max);
  }

  /// Returns `null` for missing keys; otherwise validates 0..1.
  static double? _parseUnit(Object? v, String field) {
    if (v == null) return null;
    if (v is num) {
      final d = v.toDouble();
      if (d < 0 || d > 1) {
        throw LlmJsonParseException(
          'mood_targets[].$field: $d not in [0,1]',
        );
      }
      return d;
    }
    throw LlmJsonParseException(
      'mood_targets[].$field: expected number, got ${v.runtimeType}',
    );
  }

  Map<String, dynamic> toJson() => {
        'mood': mood,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MoodTarget &&
          other.mood == mood &&
          other.min == min &&
          other.max == max);

  @override
  int get hashCode => Object.hash(mood, min, max);

  @override
  String toString() => 'MoodTarget($mood, min: $min, max: $max)';
}

/// Structured intent — the LLM's translation of the user's free-text
/// vibe. `Intent.fromJson` validates the input against `kIntentSchema`
/// (§7) using a tiny in-process checker; on any rule violation it
/// throws [LlmJsonParseException] naming the specific failure so the
/// engine's repair prompt can quote it back to the model.
@immutable
class Intent {
  final List<MoodTarget> moodTargets;

  /// Inclusive `[lo, hi]` BPM range, clamped to `[40, 220]` per
  /// schema. Null when the LLM omitted (preferred over invented).
  final (int, int)? bpmRange;

  /// Inclusive `[lo, hi]` year range, clamped to `[1950, 2100]`.
  /// Null when the LLM omitted.
  final (int, int)? era;

  final EnergyArc energyArc;

  /// Hint only; engine still trims to the requested `length`.
  final int durationMinutes;

  /// Optional seed track ids (≤ 3). When non-empty their embedding
  /// mean drives the cosine ranking; otherwise the engine falls
  /// back to `repo.meanEmbeddingForKeywords(seedKeywords)`.
  final List<int> seedTracks;

  /// Short texture nouns (`'dream pop'`, `'no vocals'`) (≤ 8).
  final List<String> seedKeywords;

  /// One-sentence narrative the LLM passes through to the refine
  /// step. ≤ 240 chars.
  final String narrative;

  const Intent({
    required this.moodTargets,
    required this.bpmRange,
    required this.era,
    required this.energyArc,
    required this.durationMinutes,
    required this.seedTracks,
    required this.seedKeywords,
    required this.narrative,
  });

  /// Total parser. On valid JSON: returns an [Intent] with unknown
  /// moods snapped via [MoodLookup]. On any structural rule miss:
  /// throws [LlmJsonParseException] with a reason field the engine
  /// can quote in its repair preamble.
  factory Intent.fromJson(Map<String, dynamic> j) {
    // Required keys.
    for (final k in const [
      'mood_targets',
      'energy_arc',
      'duration_minutes',
      'narrative',
    ]) {
      if (!j.containsKey(k)) {
        throw LlmJsonParseException('missing required field "$k"');
      }
    }

    // mood_targets: array, 1..5.
    final mtRaw = j['mood_targets'];
    if (mtRaw is! List) {
      throw LlmJsonParseException('mood_targets: expected array');
    }
    if (mtRaw.isEmpty || mtRaw.length > 5) {
      throw LlmJsonParseException(
        'mood_targets: length ${mtRaw.length} not in [1,5]',
      );
    }
    final moods = <MoodTarget>[
      for (final e in mtRaw) MoodTarget.fromJson(e),
    ];

    // bpm_range.
    final bpm = _parsePairInt(
      j['bpm_range'],
      field: 'bpm_range',
      lo: 40,
      hi: 220,
    );
    final era = _parsePairInt(
      j['era'],
      field: 'era',
      lo: 1950,
      hi: 2100,
    );

    // energy_arc.
    final arcRaw = j['energy_arc'];
    if (arcRaw is! String) {
      throw LlmJsonParseException('energy_arc: expected string');
    }
    final arc = _parseArc(arcRaw);

    // duration_minutes.
    final durRaw = j['duration_minutes'];
    if (durRaw is! num) {
      throw LlmJsonParseException('duration_minutes: expected integer');
    }
    final dur = durRaw.toInt();
    if (dur < 15 || dur > 240) {
      throw LlmJsonParseException(
        'duration_minutes: $dur not in [15,240]',
      );
    }

    // seed_tracks.
    final seedRaw = j['seed_tracks'];
    final seeds = <int>[];
    if (seedRaw != null) {
      if (seedRaw is! List) {
        throw LlmJsonParseException('seed_tracks: expected array');
      }
      if (seedRaw.length > 3) {
        throw LlmJsonParseException(
          'seed_tracks: length ${seedRaw.length} > 3',
        );
      }
      for (final v in seedRaw) {
        if (v is! num) {
          throw LlmJsonParseException(
            'seed_tracks[]: expected integer, got ${v.runtimeType}',
          );
        }
        seeds.add(v.toInt());
      }
    }

    // seed_keywords.
    final kwRaw = j['seed_keywords'];
    final keywords = <String>[];
    if (kwRaw != null) {
      if (kwRaw is! List) {
        throw LlmJsonParseException('seed_keywords: expected array');
      }
      if (kwRaw.length > 8) {
        throw LlmJsonParseException(
          'seed_keywords: length ${kwRaw.length} > 8',
        );
      }
      for (final v in kwRaw) {
        if (v is! String) {
          throw LlmJsonParseException(
            'seed_keywords[]: expected string, got ${v.runtimeType}',
          );
        }
        keywords.add(v);
      }
    }

    // narrative.
    final narrRaw = j['narrative'];
    if (narrRaw is! String) {
      throw LlmJsonParseException('narrative: expected string');
    }
    if (narrRaw.length > 240) {
      throw LlmJsonParseException(
        'narrative: length ${narrRaw.length} > 240',
      );
    }

    return Intent(
      moodTargets: List<MoodTarget>.unmodifiable(moods),
      bpmRange: bpm,
      era: era,
      energyArc: arc,
      durationMinutes: dur,
      seedTracks: List<int>.unmodifiable(seeds),
      seedKeywords: List<String>.unmodifiable(keywords),
      narrative: narrRaw,
    );
  }

  static (int, int)? _parsePairInt(
    Object? v, {
    required String field,
    required int lo,
    required int hi,
  }) {
    if (v == null) return null;
    if (v is! List) {
      throw LlmJsonParseException('$field: expected array of 2 integers');
    }
    if (v.length != 2) {
      throw LlmJsonParseException(
        '$field: length ${v.length} must be 2',
      );
    }
    if (v[0] is! num || v[1] is! num) {
      throw LlmJsonParseException('$field: items must be integers');
    }
    final a = (v[0] as num).toInt();
    final b = (v[1] as num).toInt();
    if (a < lo || a > hi || b < lo || b > hi) {
      throw LlmJsonParseException('$field: items not in [$lo,$hi]');
    }
    if (a > b) {
      throw LlmJsonParseException('$field: lo > hi ($a > $b)');
    }
    return (a, b);
  }

  static EnergyArc _parseArc(String s) {
    switch (s) {
      case 'build':
        return EnergyArc.build;
      case 'wave':
        return EnergyArc.wave;
      case 'flat':
        return EnergyArc.flat;
      case 'descend':
        return EnergyArc.descend;
      default:
        throw LlmJsonParseException(
          'energy_arc: "$s" not in [build,wave,flat,descend]',
        );
    }
  }

  /// Returns a relaxed copy: `loose` widens BPM ±10 and drops era;
  /// `veryLoose` widens BPM ±20, drops era, and keeps only the
  /// **first** mood target (the rest are dropped so the SQL filter
  /// behaves as "primary mood only" per §10 risk 5).
  Intent copyRelaxed(RelaxationLevel l) {
    if (l == RelaxationLevel.strict) return this;
    final widenBy = l == RelaxationLevel.loose ? 10 : 20;
    final newBpm = bpmRange == null
        ? null
        : (
            (bpmRange!.$1 - widenBy).clamp(40, 220),
            (bpmRange!.$2 + widenBy).clamp(40, 220),
          );
    final newMoods = l == RelaxationLevel.veryLoose && moodTargets.isNotEmpty
        ? <MoodTarget>[moodTargets.first]
        : moodTargets;
    return Intent(
      moodTargets: List<MoodTarget>.unmodifiable(newMoods),
      bpmRange: newBpm,
      era: null,
      energyArc: energyArc,
      durationMinutes: durationMinutes,
      seedTracks: seedTracks,
      seedKeywords: seedKeywords,
      narrative: narrative,
    );
  }

  /// Hand-written keyword-classifier fallback for the case where the
  /// LLM's output is unrepairable. Scans the raw vibe text for any
  /// adjective in [MoodLookup.kAdjectiveToMood]; the first match
  /// wins. If nothing matches → `relaxed` (least likely to feel
  /// wrong). Always returns a valid [Intent] — never throws.
  factory Intent.fallback(String vibe) {
    final lc = vibe.toLowerCase();
    String mood = 'relaxed';
    for (final entry in MoodLookup.kAdjectiveToMood.entries) {
      if (lc.contains(entry.key)) {
        mood = entry.value;
        break;
      }
    }
    final keywords = <String>[];
    for (final w in lc.split(RegExp(r'[^a-z0-9]+'))) {
      if (w.length >= 4 && keywords.length < 4) {
        keywords.add(w);
      }
    }
    return Intent(
      moodTargets: List<MoodTarget>.unmodifiable(
        <MoodTarget>[MoodTarget(mood: mood, min: 0.4)],
      ),
      bpmRange: null,
      era: null,
      energyArc: EnergyArc.flat,
      durationMinutes: 45,
      seedTracks: const <int>[],
      seedKeywords: List<String>.unmodifiable(keywords),
      narrative: vibe.length > 240 ? vibe.substring(0, 240) : vibe,
    );
  }

  Map<String, dynamic> toJson() => {
        'mood_targets': [for (final m in moodTargets) m.toJson()],
        if (bpmRange != null) 'bpm_range': [bpmRange!.$1, bpmRange!.$2],
        if (era != null) 'era': [era!.$1, era!.$2],
        'energy_arc': energyArc.name,
        'duration_minutes': durationMinutes,
        'seed_tracks': seedTracks,
        'seed_keywords': seedKeywords,
        'narrative': narrative,
      };

  @override
  String toString() => 'Intent(moods: ${moodTargets.length}, '
      'bpm: $bpmRange, era: $era, arc: ${energyArc.name}, '
      'dur: $durationMinutes, seeds: ${seedTracks.length}, '
      'kw: ${seedKeywords.length})';
}
