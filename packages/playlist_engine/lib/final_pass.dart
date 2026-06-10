import 'package:meta/meta.dart';

import 'llm_backend.dart' show LlmJsonParseException;

/// One LLM-proposed swap. `dropIndex` is the 0..19 slot in the
/// flow-ordered 20; `insertTrackId` is a track id sourced from the
/// remaining top-40 (engine drops out-of-pool ids in
/// `_applySwaps`).
@immutable
class Swap {
  final int dropIndex;
  final int insertTrackId;

  const Swap({required this.dropIndex, required this.insertTrackId});

  /// Total parser. Throws [LlmJsonParseException] on missing /
  /// out-of-range fields. Engine deduplicates by `dropIndex` after
  /// truncation.
  factory Swap.fromJson(Object? j) {
    if (j is! Map<String, dynamic>) {
      throw LlmJsonParseException(
        'swaps[]: expected object, got ${j.runtimeType}',
      );
    }
    final di = j['dropIndex'];
    final it = j['insertTrackId'];
    if (di is! num || di < 0 || di > 19) {
      throw LlmJsonParseException(
        'swaps[].dropIndex: $di not in [0,19]',
      );
    }
    if (it is! num) {
      throw LlmJsonParseException(
        'swaps[].insertTrackId: expected integer',
      );
    }
    return Swap(dropIndex: di.toInt(), insertTrackId: it.toInt());
  }

  Map<String, dynamic> toJson() => {
        'dropIndex': dropIndex,
        'insertTrackId': insertTrackId,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Swap &&
          other.dropIndex == dropIndex &&
          other.insertTrackId == insertTrackId);

  @override
  int get hashCode => Object.hash(dropIndex, insertTrackId);

  @override
  String toString() => 'Swap(drop: $dropIndex, insert: $insertTrackId)';
}

/// Result of the LLM's narrative pass: ≤ 4 swaps + a ≤ 2-sentence
/// blurb. `fromJson` truncates silently to those limits per §10
/// risk 7.
@immutable
class FinalPass {
  /// At most 4 swaps. Order preserved from the model's response,
  /// but de-duplicated by `dropIndex` (last write wins).
  final List<Swap> swaps;

  /// At most 2 sentences and 240 chars. Trailing whitespace
  /// stripped; ends include the final terminator.
  final String blurb;

  const FinalPass({required this.swaps, required this.blurb});

  /// Total parser; never throws on excess swaps or long blurbs —
  /// truncates instead. Throws [LlmJsonParseException] only on
  /// outright structural failures (wrong types, missing keys).
  factory FinalPass.fromJson(Map<String, dynamic> j) {
    final swapsRaw = j['swaps'];
    if (swapsRaw != null && swapsRaw is! List) {
      throw LlmJsonParseException('swaps: expected array');
    }
    final all = <Swap>[];
    if (swapsRaw is List) {
      for (final s in swapsRaw) {
        all.add(Swap.fromJson(s));
      }
    }
    // Dedup by dropIndex (later proposals overwrite earlier ones),
    // preserve order of first appearance.
    final byIndex = <int, Swap>{};
    final order = <int>[];
    for (final s in all) {
      if (!byIndex.containsKey(s.dropIndex)) order.add(s.dropIndex);
      byIndex[s.dropIndex] = s;
    }
    final deduped = <Swap>[for (final i in order) byIndex[i]!];
    final truncated = deduped.length <= 4 ? deduped : deduped.sublist(0, 4);

    final blurbRaw = j['blurb'];
    if (blurbRaw is! String) {
      throw LlmJsonParseException('blurb: expected string');
    }
    final trimmedBlurb = _trimBlurb(blurbRaw);

    return FinalPass(
      swaps: List<Swap>.unmodifiable(truncated),
      blurb: trimmedBlurb,
    );
  }

  /// Trims [raw] to ≤ 2 sentence terminators (`.`, `!`, `?`) or
  /// ≤ 240 chars, whichever fires first. Preserves the terminator.
  static String _trimBlurb(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    var sentences = 0;
    var idx = -1;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == '.' || ch == '!' || ch == '?') {
        sentences++;
        if (sentences == 2) {
          idx = i;
          break;
        }
      }
    }
    if (idx >= 0) {
      s = s.substring(0, idx + 1);
    }
    if (s.length > 240) {
      s = s.substring(0, 240);
    }
    return s.trimRight();
  }

  Map<String, dynamic> toJson() => {
        'swaps': [for (final s in swaps) s.toJson()],
        'blurb': blurb,
      };

  @override
  String toString() => 'FinalPass(swaps: ${swaps.length}, '
      'blurb: ${blurb.length} chars)';
}
