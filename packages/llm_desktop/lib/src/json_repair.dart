/// Best-effort cleanup pass run on the raw text the LLM emits before
/// the caller hands it to `jsonDecode`. Targets three observed Qwen3
/// failure modes (Track-B doc-refresh §4):
///
/// 1. **Leading `<think>…</think>` reasoning** — Qwen3 emits these
///    even in JSON mode when `enable_thinking=True` (Ollama's default
///    Modelfile keeps thinking on). Greedy strip across newlines.
/// 2. **Markdown code fences** — ` ```json … ``` ` or just ` ``` … ```
///    wrappers. Strip both fences and the optional language tag.
/// 3. **Trailing prose** — text after the closing `}` of the JSON
///    object. Trim everything before the first `{` and after the
///    matching final `}`.
///
/// On any unrepairable input (no `{...}` substring, dangling
/// `<think>` tag) [repairForJson] returns the input as-is so the
/// caller's `jsonDecode` throws a sensible [FormatException] that the
/// engine repair loop can quote.
String repairForJson(String raw) {
  var s = raw;

  // (1) Strip a leading <think>...</think> block. Greedy across
  // newlines. Only the FIRST occurrence is stripped — later
  // <think> tags inside the JSON payload would be a model bug we
  // don't try to paper over.
  s = _stripLeadingThink(s);

  // (2) Strip markdown code fences. Recognises ```json, ```JSON,
  // and bare ``` openers, plus the trailing ```.
  s = _stripCodeFences(s);

  // (3) Trim leading/trailing prose. Find the first `{` and the
  // matching outermost `}` (rightmost one is good enough for
  // well-formed JSON; if the model emitted a stray `}` in a string
  // literal that's a model bug we let through).
  final start = s.indexOf('{');
  final end = s.lastIndexOf('}');
  if (start >= 0 && end > start) {
    s = s.substring(start, end + 1);
  }

  return s.trim();
}

/// Strips a leading `<think>...</think>` block, including any
/// preceding whitespace. Only triggers when the trimmed input starts
/// with `<think>`. Returns the input unchanged when there's no
/// closing tag (the engine repair loop catches the malformed JSON).
String _stripLeadingThink(String s) {
  final ltrim = s.trimLeft();
  // Lowercased to match `<Think>` / `<THINK>` defensively, though
  // Qwen3 uses lowercase.
  final lower = ltrim.toLowerCase();
  if (!lower.startsWith('<think>')) return s;
  final closeIdx = lower.indexOf('</think>');
  if (closeIdx < 0) {
    // Dangling open tag — leave it; jsonDecode will fail and the
    // engine will issue a repair prompt naming the issue.
    return s;
  }
  // Strip from the original (preserving casing in the rest of the
  // string) starting at the closing tag's end.
  final headLen = s.length - ltrim.length; // leading whitespace count
  final after = ltrim.substring(closeIdx + '</think>'.length);
  return ' ' * headLen + after;
}

/// Strips Markdown code fences. Handles all common forms:
///   ```json\n{...}\n```
///   ```JSON\n{...}\n```
///   ```\n{...}\n```
///   `{...}` wrapped on a single line with backticks ` ```{...}``` `
String _stripCodeFences(String s) {
  var out = s;

  // Locate the FIRST opening fence. We don't run a full lexer; the
  // string is short and the pattern is fixed.
  final openIdx = out.indexOf('```');
  if (openIdx < 0) return out;

  // Skip the opener and an optional language tag (alphabetics until
  // newline).
  var i = openIdx + 3;
  while (i < out.length && _isLangTagChar(out.codeUnitAt(i))) {
    i++;
  }
  // Skip exactly one trailing newline (\n or \r\n) after the lang tag,
  // if present, so the body starts cleanly.
  if (i < out.length && out.codeUnitAt(i) == 0x0D /* \r */) i++;
  if (i < out.length && out.codeUnitAt(i) == 0x0A /* \n */) i++;

  // Locate the FINAL closing fence after the opener.
  final closeIdx = out.lastIndexOf('```');
  if (closeIdx <= openIdx) return out; // no matching close — bail.

  final body = out.substring(i, closeIdx);
  // Preserve content before the opener (usually empty / prose) so
  // the later `{` index search still works.
  final head = out.substring(0, openIdx);
  final tail = out.substring(closeIdx + 3);
  out = '$head$body$tail';
  return out;
}

bool _isLangTagChar(int c) {
  // ASCII letters + digits — language tags like `json`, `JSON5`.
  return (c >= 0x41 && c <= 0x5A) || // A–Z
      (c >= 0x61 && c <= 0x7A) || // a–z
      (c >= 0x30 && c <= 0x39); // 0–9
}
