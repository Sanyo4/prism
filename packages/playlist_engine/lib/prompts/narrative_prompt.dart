/// `kNarrativeSystem` — system prompt for the LLM's narrative pass
/// (`LlmBackend.refine`, temperature 0.7).
///
/// The user message that accompanies this system prompt is built by
/// the backend; it carries the parsed [`Intent`] (as JSON) and the
/// 20 ordered candidates serialized one row per line as:
///
///   `id | title | artist | bpm | key | year`
///
/// — see [formatCandidatesForRefine]. The model returns strict JSON
/// matching `FinalPass.fromJson`'s shape: at most 4 swaps and a
/// blurb of at most 2 sentences.
library;

import '../repo.dart';

/// Locked system prompt for the narrative pass. Plain text (no
/// schema substitution) — `refine` uses `format: "json"` rather
/// than schema-mode because the swap shape is small and Qwen3
/// reliably emits two-key JSON in plain JSON mode.
const String kNarrativeSystem = r'''Given (1) intent, (2) 20 ordered candidates, return STRICT JSON with ≤4 swaps that improve narrative flow and a blurb ≤2 sentences. MAY drop / promote; MUST NOT invent ids, swap >4, or reorder beyond declared swaps (engine re-orders).
Shape: {"swaps":[{"dropIndex":<0..19>,"insertTrackId":<int>}],"blurb":"<=2 sentences"}
''';

/// Format a list of [CandidateMeta] as one row per line, matching
/// the row format documented in [kNarrativeSystem]. The backend
/// uses this to build the user message paired with the system
/// prompt.
///
/// Row format: `id | title | artist | ${bpm.toStringAsFixed(0)} |
/// key | ${year ?? "—"}`. Title and artist are escape-free; the
/// pipe separator is preferred over commas because some titles
/// contain commas. Empty `key` renders as the literal `"-"`.
String formatCandidatesForRefine(List<CandidateMeta> ordered) {
  final lines = <String>[];
  for (final c in ordered) {
    final bpm = c.bpm.toStringAsFixed(0);
    final key = c.key.isEmpty ? '-' : c.key;
    final year = c.year?.toString() ?? '—';
    lines.add('${c.trackId} | ${c.title} | ${c.artistKey} | '
        '$bpm | $key | $year');
  }
  return lines.join('\n');
}
