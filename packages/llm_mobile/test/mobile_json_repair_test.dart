import 'package:prism_llm_mobile/llm_mobile.dart';
import 'package:test/test.dart';

void main() {
  group('MobileJsonRepair.clean', () {
    test('plain JSON object passes through unchanged', () {
      const raw = '{"mood_targets":[{"mood":"sad"}],"narrative":"x"}';
      expect(MobileJsonRepair.clean(raw), raw);
    });

    test('strips a ```json fence', () {
      const raw = '```json\n{"a":1}\n```';
      expect(MobileJsonRepair.clean(raw), '{"a":1}');
    });

    test('strips a bare ``` fence (no language tag)', () {
      const raw = '```\n{"a": 1}\n```';
      expect(MobileJsonRepair.clean(raw), '{"a": 1}');
    });

    test('strips a leading <think> block', () {
      const raw = '<think>plan…</think>{"mood":"happy"}';
      expect(MobileJsonRepair.clean(raw), '{"mood":"happy"}');
    });

    test('strips a multi-line <think> block', () {
      const raw =
          '<think>\nReasoning step 1.\nReasoning step 2.\n</think>\n\n{"swaps":[],"blurb":"ok"}\n';
      expect(MobileJsonRepair.clean(raw), '{"swaps":[],"blurb":"ok"}');
    });

    test('strips a <tool_call> envelope anywhere in the input', () {
      const raw =
          '<tool_call>{"name":"foo"}</tool_call>{"mood":"relaxed","narrative":"y"}';
      expect(
        MobileJsonRepair.clean(raw),
        '{"mood":"relaxed","narrative":"y"}',
      );
    });

    test('strips multiple <tool_call> envelopes', () {
      const raw = '<tool_call>{"a":1}</tool_call>'
          '<tool_call>{"b":2}</tool_call>'
          '{"mood":"sad"}';
      expect(MobileJsonRepair.clean(raw), '{"mood":"sad"}');
    });

    test('strips <think> AND <tool_call> AND fences in the same payload', () {
      const raw = '<think>plan</think>'
          '<tool_call>{"x":1}</tool_call>\n'
          '```json\n{"mood":"party"}\n```\n';
      expect(MobileJsonRepair.clean(raw), '{"mood":"party"}');
    });

    test('strips trailing prose after the closing brace', () {
      const raw = 'Here is the JSON: '
          '{"mood":"sad","note":"hi"} '
          'Hope this helps!';
      expect(MobileJsonRepair.clean(raw), '{"mood":"sad","note":"hi"}');
    });

    test('keeps nested braces inside a string literal', () {
      // The inner `{nested}` is inside a JSON string; the outer
      // brace counter must NOT match against it.
      const raw = '{"narrative":"a {nested} thing","x":1}trailing';
      expect(
        MobileJsonRepair.clean(raw),
        '{"narrative":"a {nested} thing","x":1}',
      );
    });

    test('keeps escaped quotes inside a string literal', () {
      const raw = '{"q":"she said \\"hi\\"","x":1}';
      expect(MobileJsonRepair.clean(raw), '{"q":"she said \\"hi\\"","x":1}');
    });

    test('returns input unchanged when no balanced JSON object exists', () {
      const raw = 'sorry, I cannot answer in JSON';
      expect(MobileJsonRepair.clean(raw), raw);
    });

    test('returns input unchanged when the JSON object is unterminated', () {
      // `<think>` strip kicks in (closer is present) but the JSON
      // body is missing a closing brace — brace counter never
      // returns to 0, falls through to the "unrepairable" branch.
      const raw = '<think>x</think>{"a":1';
      expect(MobileJsonRepair.clean(raw), contains('{"a":1'));
    });

    test('handles dangling <think> by skipping the strip', () {
      // No closing tag → strip bails. The brace extractor still
      // pulls the {"a":1} block out.
      const raw = '<think>partial reasoning…\n{"a":1}\n';
      expect(MobileJsonRepair.clean(raw), '{"a":1}');
    });

    test('handles capitalised <Think> tag (case-insensitive)', () {
      const raw = '<Think>plan</Think>\n{"a":1}';
      expect(MobileJsonRepair.clean(raw), '{"a":1}');
    });

    test('handles capitalised <Tool_Call> tag', () {
      const raw = '<TOOL_CALL>{"x":1}</TOOL_CALL>{"y":2}';
      expect(MobileJsonRepair.clean(raw), '{"y":2}');
    });

    test('returns the FIRST balanced object when two are present', () {
      // Caller's `Intent.fromJson` only wants one object — we pick
      // the first balanced block.
      const raw = '{"mood":"sad"}{"mood":"happy"}';
      expect(MobileJsonRepair.clean(raw), '{"mood":"sad"}');
    });

    test('does not match braces inside an escape-terminated string', () {
      // The trailing backslash in the string would, naively, swallow
      // the closing `"`. Our brace walker handles this: `\\` is two
      // chars (backslash + backslash), so the next `"` correctly
      // closes the string and the outer `}` finishes the object.
      const raw = r'{"path":"C:\\Users\\","ok":true}';
      expect(MobileJsonRepair.clean(raw), r'{"path":"C:\\Users\\","ok":true}');
    });
  });
}
