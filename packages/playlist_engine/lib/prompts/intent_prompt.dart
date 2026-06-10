/// `kIntentSchema` and `kIntentSystem` — byte-locked prompt
/// surfaces for slice 6's intent pass.
///
/// Both literals are frozen by `intent_prompt_test.dart`. Changes
/// here must be reviewed against the spec (slice plan §7) and the
/// schema substitution must keep rendering valid JSON Schema (the
/// test exercises the substitution and checks it parses + has the
/// expected `properties` keys).
library;

/// JSON Schema (Draft 2020-12) the LLM's intent output must
/// validate against. Sent verbatim to Ollama as the `format` field
/// (object) when the daemon supports schema-mode; otherwise the
/// backend falls back to `format: "json"` and the engine's
/// `Intent.fromJson` checker enforces the same rules in-process.
const String kIntentSchema = r'''
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "required": ["mood_targets", "energy_arc", "duration_minutes", "narrative"],
  "properties": {
    "mood_targets": {
      "type": "array", "minItems": 1, "maxItems": 5,
      "items": {
        "type": "object", "required": ["mood"], "additionalProperties": false,
        "properties": {
          "mood": {"type":"string","enum":["happy","sad","aggressive","relaxed","party"]},
          "min":  {"type":"number","minimum":0,"maximum":1},
          "max":  {"type":"number","minimum":0,"maximum":1}
        }
      }
    },
    "bpm_range": {"type":"array","minItems":2,"maxItems":2,
                  "items":{"type":"integer","minimum":40,"maximum":220}},
    "era":       {"type":"array","minItems":2,"maxItems":2,
                  "items":{"type":"integer","minimum":1950,"maximum":2100}},
    "energy_arc":       {"type":"string","enum":["build","wave","flat","descend"]},
    "duration_minutes": {"type":"integer","minimum":15,"maximum":240},
    "seed_tracks":   {"type":"array","items":{"type":"integer"},"maxItems":3,"default":[]},
    "seed_keywords": {"type":"array","items":{"type":"string"},"maxItems":8,"default":[]},
    "narrative":     {"type":"string","maxLength":240}
  }
}
''';

/// System prompt for `LlmBackend.buildIntent` (temperature 0.1).
/// Contains a literal `{kIntentSchema}` placeholder which the
/// backend substitutes before sending. The substituted prompt is
/// what `intent_prompt_test.dart` locks byte-for-byte.
const String kIntentSystem = r'''Convert the user's free-text "vibe" into strict JSON. Return ONLY JSON, no prose, no code fences. Moods ∈ {happy, sad, aggressive, relaxed, party}. Arcs ∈ {build, wave, flat, descend}. BPM ∈ [40,220]. Era ∈ [1950,2100]. duration ∈ [15,240]. Prefer omitting bpm_range/era over inventing. seed_keywords = short texture nouns ("dream pop", "no vocals"); leave seed_tracks empty. Output MUST validate against:
{kIntentSchema}
Example in:  "rainy Sunday morning, low BPM, no vocals"
Example out: {"mood_targets":[{"mood":"relaxed","min":0.5},{"mood":"aggressive","max":0.2}],"bpm_range":[60,95],"energy_arc":"flat","duration_minutes":45,"seed_tracks":[],"seed_keywords":["ambient","instrumental","rainy"],"narrative":"calm rainy morning, no vocals"}
''';

/// Substitute the `{kIntentSchema}` placeholder in [kIntentSystem]
/// with the actual schema literal. Backends call this once at
/// request build time; the engine's tests lock both the unsubstituted
/// and the substituted strings.
String renderIntentSystem() => kIntentSystem.replaceFirst(
      '{kIntentSchema}',
      kIntentSchema.trim(),
    );
