import 'package:prism_llm_desktop/llm_desktop.dart' show repairForJson;
import 'package:test/test.dart';

void main() {
  group('repairForJson', () {
    test('strips ```json fences and trims to the JSON object', () {
      final raw = '''
```json
{"mood_targets":[{"mood":"sad"}],"narrative":"x"}
```
''';
      final out = repairForJson(raw);
      expect(out,
          '{"mood_targets":[{"mood":"sad"}],"narrative":"x"}');
    });

    test('strips bare ``` fences (no language tag)', () {
      final raw = '''
```
{"a": 1}
```
''';
      expect(repairForJson(raw), '{"a": 1}');
    });

    test('strips trailing prose after the closing brace', () {
      final raw = 'Here is the JSON you asked for:\n'
          '{"mood":"sad","note":"hi"}\n'
          'Hope this helps!';
      expect(repairForJson(raw), '{"mood":"sad","note":"hi"}');
    });

    test('strips a single-line leading <think> block', () {
      final raw = '<think>I should answer with JSON.</think>{"a":1}';
      expect(repairForJson(raw), '{"a":1}');
    });

    test('strips a multi-line leading <think> block', () {
      final raw = '<think>\n'
          'Reasoning step 1.\n'
          'Reasoning step 2.\n'
          'Final: emit JSON.\n'
          '</think>\n'
          '\n'
          '{"swaps":[],"blurb":"ok"}\n';
      expect(repairForJson(raw), '{"swaps":[],"blurb":"ok"}');
    });

    test('strips <think> and code fence in the same payload', () {
      final raw = '<think>plan…</think>\n'
          '```json\n'
          '{"mood":"happy"}\n'
          '```\n';
      expect(repairForJson(raw), '{"mood":"happy"}');
    });

    test('returns input unchanged when no JSON object is present', () {
      // No `{`/`}` pair — substring trim path leaves the trimmed
      // raw string intact (caller's jsonDecode will fail, engine
      // will issue a repair prompt).
      final raw = 'sorry, I cannot answer in JSON';
      expect(repairForJson(raw), 'sorry, I cannot answer in JSON');
    });

    test('leaves dangling <think> alone (no closing tag)', () {
      // Without a closing tag we can't safely strip — let the engine
      // surface the malformed input.
      final raw = '<think>partial reasoning…\n{"a":1}\n';
      // The trim-to-`{...}` step still kicks in; the leading
      // `<think>` survives because the strip step bails. The
      // outermost `{` is the one in the JSON, so the result
      // includes everything from there through `}`.
      expect(repairForJson(raw), '{"a":1}');
    });

    test('handles a code block with no surrounding prose', () {
      final raw = '```json\n{"mood":"sad"}\n```';
      expect(repairForJson(raw), '{"mood":"sad"}');
    });

    test('handles capitalised <Think> tag (case-insensitive)', () {
      final raw = '<Think>Plan…</Think>\n{"a":1}';
      expect(repairForJson(raw), '{"a":1}');
    });

    test('preserves nested braces inside a string', () {
      // Outer `}` is the last `}`; everything between the first `{`
      // and the last `}` is preserved.
      final raw = 'noise{"narrative":"a {nested} thing","x":1}trailing';
      expect(
        repairForJson(raw),
        '{"narrative":"a {nested} thing","x":1}',
      );
    });
  });
}
