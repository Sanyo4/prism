import 'dart:convert';

import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:test/test.dart';

void main() {
  group('kIntentSchema', () {
    test('byte-frozen — must match the spec literal verbatim', () {
      // Slice plan §7 inlines this schema as the locked literal.
      // Any drift here is a slice-6 spec change and must update the
      // plan + this test together.
      const expected = r'''
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
      expect(kIntentSchema, expected);
    });

    test('parses to valid JSON', () {
      final decoded = jsonDecode(kIntentSchema);
      expect(decoded, isA<Map<String, dynamic>>());
      final m = decoded as Map<String, dynamic>;
      expect(m[r'$schema'], 'https://json-schema.org/draft/2020-12/schema');
      expect(m['type'], 'object');
      expect(m['additionalProperties'], false);
      expect(m['required'], const [
        'mood_targets',
        'energy_arc',
        'duration_minutes',
        'narrative',
      ]);
    });

    test('properties cover every required Intent field', () {
      final m = jsonDecode(kIntentSchema) as Map<String, dynamic>;
      final props = m['properties'] as Map<String, dynamic>;
      const expectedKeys = {
        'mood_targets',
        'bpm_range',
        'era',
        'energy_arc',
        'duration_minutes',
        'seed_tracks',
        'seed_keywords',
        'narrative',
      };
      expect(props.keys.toSet(), expectedKeys);
    });

    test('mood enum locked to the 5-class vocabulary', () {
      final m = jsonDecode(kIntentSchema) as Map<String, dynamic>;
      final props = m['properties'] as Map<String, dynamic>;
      final mt = props['mood_targets'] as Map<String, dynamic>;
      final items = mt['items'] as Map<String, dynamic>;
      final iProps = items['properties'] as Map<String, dynamic>;
      final moodSchema = iProps['mood'] as Map<String, dynamic>;
      expect(moodSchema['enum'], const [
        'happy',
        'sad',
        'aggressive',
        'relaxed',
        'party',
      ]);
    });

    test('arc enum locked', () {
      final m = jsonDecode(kIntentSchema) as Map<String, dynamic>;
      final props = m['properties'] as Map<String, dynamic>;
      final arc = props['energy_arc'] as Map<String, dynamic>;
      expect(arc['enum'], const ['build', 'wave', 'flat', 'descend']);
    });
  });

  group('kIntentSystem', () {
    test('byte-frozen — must match the spec text verbatim', () {
      const expected =
          r'''Convert the user's free-text "vibe" into strict JSON. Return ONLY JSON, no prose, no code fences. Moods ∈ {happy, sad, aggressive, relaxed, party}. Arcs ∈ {build, wave, flat, descend}. BPM ∈ [40,220]. Era ∈ [1950,2100]. duration ∈ [15,240]. Prefer omitting bpm_range/era over inventing. seed_keywords = short texture nouns ("dream pop", "no vocals"); leave seed_tracks empty. Output MUST validate against:
{kIntentSchema}
Example in:  "rainy Sunday morning, low BPM, no vocals"
Example out: {"mood_targets":[{"mood":"relaxed","min":0.5},{"mood":"aggressive","max":0.2}],"bpm_range":[60,95],"energy_arc":"flat","duration_minutes":45,"seed_tracks":[],"seed_keywords":["ambient","instrumental","rainy"],"narrative":"calm rainy morning, no vocals"}
''';
      expect(kIntentSystem, expected);
    });

    test('contains the {kIntentSchema} substitution marker exactly once', () {
      final occurrences = '{kIntentSchema}'.allMatches(kIntentSystem).length;
      expect(occurrences, 1);
    });

    test('renderIntentSystem substitutes the placeholder with valid schema',
        () {
      final rendered = renderIntentSystem();
      expect(rendered.contains('{kIntentSchema}'), isFalse);
      // Anchor on the schema's $schema URL — appears exactly once
      // in the rendered prompt, inside the substituted JSON Schema
      // block. Walk back to the nearest `{` to grab the start.
      final schemaIdx = rendered.indexOf(r'"$schema"');
      expect(schemaIdx, greaterThan(0),
          reason: 'rendered prompt missing schema literal');
      final start = rendered.lastIndexOf('{', schemaIdx);
      expect(start, greaterThanOrEqualTo(0),
          reason: 'rendered prompt missing schema opening brace');
      // The schema's matching closer is at the last '}' before
      // 'Example in:'.
      final exampleIdx = rendered.indexOf('Example in:');
      expect(exampleIdx, greaterThan(start));
      final endBrace = rendered.lastIndexOf('}', exampleIdx);
      expect(endBrace, greaterThan(start));
      final raw = rendered.substring(start, endBrace + 1);
      final decoded = jsonDecode(raw);
      expect(decoded, isA<Map<String, dynamic>>());
      final m = decoded as Map<String, dynamic>;
      expect(m['type'], 'object');
      expect((m['properties'] as Map<String, dynamic>).keys,
          containsAll(['mood_targets', 'energy_arc', 'narrative']));
    });
  });

  group('MoodLookup', () {
    test('canonical moods are idempotent', () {
      for (final m in MoodLookup.kCanonicalMoods) {
        expect(MoodLookup.snap(m), m);
      }
    });

    test('case-insensitive + trim', () {
      expect(MoodLookup.snap('  Melancholic '), 'sad');
      expect(MoodLookup.snap('EUPHORIC'), 'happy');
    });

    test('table covers the 40+ adjectives in the spec', () {
      // Sentinel adjectives spec plan §10 risk 4 calls out plus a
      // sampling of the rest of the table.
      const cases = {
        // happy
        'happy': 'happy',
        'cheerful': 'happy',
        'euphoric': 'happy',
        'uplifting': 'happy',
        'sunny': 'happy',
        'upbeat': 'happy',
        // sad
        'sad': 'sad',
        'melancholic': 'sad',
        'melancholy': 'sad',
        'brooding': 'sad',
        'nostalgic': 'sad',
        'mournful': 'sad',
        'lonely': 'sad',
        // aggressive
        'aggressive': 'aggressive',
        'angry': 'aggressive',
        'rage': 'aggressive',
        'metal': 'aggressive',
        'intense': 'aggressive',
        'hardcore': 'aggressive',
        // relaxed
        'relaxed': 'relaxed',
        'chill': 'relaxed',
        'mellow': 'relaxed',
        'rainy': 'relaxed',
        'ambient': 'relaxed',
        'lofi': 'relaxed',
        'drive': 'relaxed',
        // party
        'party': 'party',
        'dance': 'party',
        'energetic': 'party',
        'club': 'party',
        'banger': 'party',
        'hype': 'party',
      };
      for (final entry in cases.entries) {
        expect(MoodLookup.snap(entry.key), entry.value,
            reason: 'snap("${entry.key}") expected ${entry.value}');
      }
      // Total table size — a sanity check that the file wasn't
      // pruned. Exact count documented; bump when expanding.
      expect(MoodLookup.kAdjectiveToMood.length, greaterThanOrEqualTo(40));
    });

    test('unknowns default to relaxed', () {
      expect(MoodLookup.snap('xenobiology'), 'relaxed');
      expect(MoodLookup.snap(''), 'relaxed');
      expect(MoodLookup.snap('   '), 'relaxed');
    });

    test('every table value is one of the 5 canonical moods', () {
      final canonical = MoodLookup.kCanonicalMoods.toSet();
      for (final v in MoodLookup.kAdjectiveToMood.values) {
        expect(canonical.contains(v), isTrue,
            reason: 'mood "$v" not in canonical set');
      }
    });
  });

  group('Intent.fromJson — schema enforcement', () {
    test('valid JSON → Intent', () {
      final j = {
        'mood_targets': [
          {'mood': 'sad', 'min': 0.5}
        ],
        'energy_arc': 'flat',
        'duration_minutes': 45,
        'narrative': 'calm rainy morning'
      };
      final intent = Intent.fromJson(j);
      expect(intent.moodTargets.first.mood, 'sad');
      expect(intent.energyArc, EnergyArc.flat);
      expect(intent.durationMinutes, 45);
    });

    test('unknown moods snap to canonical via MoodLookup', () {
      final j = {
        'mood_targets': [
          {'mood': 'melancholic'}
        ],
        'energy_arc': 'flat',
        'duration_minutes': 45,
        'narrative': 'late night'
      };
      final intent = Intent.fromJson(j);
      expect(intent.moodTargets.first.mood, 'sad');
    });

    test('missing required field throws LlmJsonParseException', () {
      expect(
        () => Intent.fromJson(<String, dynamic>{
          'mood_targets': [
            {'mood': 'sad'}
          ],
          'energy_arc': 'flat',
          // duration_minutes missing
          'narrative': 'foo',
        }),
        throwsA(isA<LlmJsonParseException>()),
      );
    });

    test('out-of-range bpm throws', () {
      expect(
        () => Intent.fromJson(<String, dynamic>{
          'mood_targets': [
            {'mood': 'sad'}
          ],
          'bpm_range': [10, 90],
          'energy_arc': 'flat',
          'duration_minutes': 45,
          'narrative': 'foo',
        }),
        throwsA(isA<LlmJsonParseException>()),
      );
    });

    test('Intent.fallback is total — never throws', () {
      final intent = Intent.fallback('rainy chill drive');
      expect(intent.moodTargets, isNotEmpty);
      // At least one of: 'rainy' (relaxed), 'chill' (relaxed),
      // 'drive' (relaxed) → snap to relaxed.
      expect(intent.moodTargets.first.mood, 'relaxed');
    });

    test('Intent.fallback on empty input still returns a valid Intent', () {
      final intent = Intent.fallback('');
      expect(intent.moodTargets.first.mood, 'relaxed');
      expect(intent.narrative, '');
    });
  });

  group('FinalPass.fromJson — truncation', () {
    test('truncates >4 swaps', () {
      final j = {
        'swaps': [
          for (var i = 0; i < 6; i++)
            {'dropIndex': i, 'insertTrackId': 100 + i},
        ],
        'blurb': 'ok.',
      };
      final fp = FinalPass.fromJson(j);
      expect(fp.swaps.length, 4);
    });

    test('trims blurb to ≤2 sentences', () {
      final j = {
        'swaps': const <Object>[],
        'blurb': 'One. Two. Three. Four.',
      };
      final fp = FinalPass.fromJson(j);
      expect(fp.blurb, 'One. Two.');
    });

    test('clamps blurb to 240 chars even with no terminator', () {
      final long = 'x' * 400;
      final fp = FinalPass.fromJson({'swaps': const <Object>[], 'blurb': long});
      expect(fp.blurb.length, 240);
    });
  });
}
