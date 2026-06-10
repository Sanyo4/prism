/// `MobileJsonRepair.clean` — best-effort response-side cleanup for
/// raw text Cactus / Qwen3 emits before it reaches `jsonDecode`.
///
/// Slice-6 desktop (`packages/llm_desktop/lib/src/json_repair.dart`)
/// already handles `<think>` + Markdown fences + leading/trailing
/// prose for the Ollama path. This mobile equivalent extends with the
/// `<tool_call>…</tool_call>` envelope (slice-8 §10 risk 7) that the
/// Cactus tokenizer leaks into JSON-mode responses and a brace-balanced
/// extractor that respects strings + escape sequences.
///
/// Strip order (per slice-8 §7):
///  1. Leading `<think>...</think>` (non-greedy, first occurrence only).
///  2. `<tool_call>...</tool_call>` (anywhere; non-greedy; all occurrences).
///  3. Markdown code fences — ```` ```json `` `` and bare ``` ```` ```.
///  4. Prose before the first `{` / after the last balanced `}`.
///  5. Walk a brace counter that respects double-quoted strings and
///     `\`-escape sequences, returning the FIRST balanced `{...}` block.
///
/// Never throws. On unrepairable input (no balanced `{...}` found),
/// returns the input as-is so the caller's `jsonDecode` raises a
/// `FormatException` that the slice-6 `PlaylistEngine` repair loop
/// can reason about.
library;

class MobileJsonRepair {
  MobileJsonRepair._();

  /// Pure function. Total — never throws.
  static String clean(String raw) {
    var s = raw;

    // (1) Leading `<think>...</think>`. Greedy across newlines, only
    // the first occurrence; if the closer is missing, leave the
    // string alone — the engine repair loop will quote the malformed
    // payload back to the model.
    s = _stripLeadingThink(s);

    // (2) Strip every `<tool_call>...</tool_call>` envelope. Cactus's
    // Qwen3 tokenizer emits these even in JSON mode (§10 risk 7); we
    // never invoke the tool, so simply drop the wrapper.
    s = _stripToolCalls(s);

    // (3) Strip Markdown code fences (```json ... ```, ``` ... ```).
    s = _stripCodeFences(s);

    // (4) + (5) Locate the first balanced `{...}` block. Walks a
    // brace counter that respects string literals and escapes.
    final extracted = _firstBalancedJsonObject(s);
    if (extracted != null) {
      return extracted;
    }
    // No balanced object found — return input unchanged. Caller
    // raises `LlmJsonParseException` at `Intent.fromJson`.
    return s;
  }
}

/// Strips a leading `<think>...</think>` block (first occurrence only).
/// Whitespace before the tag is preserved-ish (replaced with a single
/// space to keep column 0 visible during debug). Case-insensitive on
/// the open/close tag — Qwen3 uses lowercase but we defend.
String _stripLeadingThink(String s) {
  final ltrim = s.trimLeft();
  final lower = ltrim.toLowerCase();
  if (!lower.startsWith('<think>')) return s;
  final closeIdx = lower.indexOf('</think>');
  if (closeIdx < 0) {
    // Dangling open — let the caller surface the malformed input.
    return s;
  }
  final headLen = s.length - ltrim.length;
  final after = ltrim.substring(closeIdx + '</think>'.length);
  return ' ' * headLen + after;
}

/// Strips every `<tool_call>...</tool_call>` envelope (non-greedy).
/// Multiple occurrences anywhere in the string. Case-insensitive.
String _stripToolCalls(String s) {
  // Pattern: `<tool_call>` ... `</tool_call>`, non-greedy `.*?`,
  // dotall so newlines inside the tool-call payload don't break the
  // match.
  final re = RegExp(
    r'<tool_call>.*?</tool_call>',
    caseSensitive: false,
    dotAll: true,
  );
  return s.replaceAll(re, '');
}

/// Strips a single ```` ```json ... ``` ```` (or bare ` ``` `) fence.
/// Mirrors slice-6 `_stripCodeFences` — opener may carry an
/// alphanumeric language tag; closer is the FINAL ``` after the
/// opener. If no opener is present, returns the input unchanged.
String _stripCodeFences(String s) {
  final openIdx = s.indexOf('```');
  if (openIdx < 0) return s;
  // Skip opener + optional language tag (alphanumerics until newline).
  var i = openIdx + 3;
  while (i < s.length && _isLangTagChar(s.codeUnitAt(i))) {
    i++;
  }
  // Skip exactly one trailing CR + LF (or just LF).
  if (i < s.length && s.codeUnitAt(i) == 0x0D) i++;
  if (i < s.length && s.codeUnitAt(i) == 0x0A) i++;

  final closeIdx = s.lastIndexOf('```');
  if (closeIdx <= openIdx) return s;

  final head = s.substring(0, openIdx);
  final body = s.substring(i, closeIdx);
  final tail = s.substring(closeIdx + 3);
  return '$head$body$tail';
}

bool _isLangTagChar(int c) {
  return (c >= 0x41 && c <= 0x5A) || // A–Z
      (c >= 0x61 && c <= 0x7A) || // a–z
      (c >= 0x30 && c <= 0x39); // 0–9
}

/// Walks [s] looking for the FIRST balanced `{...}` block, respecting
/// double-quoted strings and `\`-escape sequences inside them. Returns
/// the substring spanning the opening `{` through the matched closing
/// `}`, or `null` if the input has no balanced block.
///
/// This is sturdier than `s.indexOf('{') .. s.lastIndexOf('}')` (the
/// slice-6 desktop strategy) — it correctly handles outputs where a
/// top-level JSON object precedes a stray `}` inside a string later
/// in the buffer. Slice-8 §7 calls this out explicitly.
String? _firstBalancedJsonObject(String s) {
  final start = s.indexOf('{');
  if (start < 0) return null;

  var depth = 0;
  var inString = false;
  var escape = false;

  for (var i = start; i < s.length; i++) {
    final ch = s.codeUnitAt(i);
    if (escape) {
      // Previous char was `\` inside a string — skip this one.
      escape = false;
      continue;
    }
    if (inString) {
      if (ch == 0x5C /* \ */) {
        escape = true;
      } else if (ch == 0x22 /* " */) {
        inString = false;
      }
      continue;
    }
    if (ch == 0x22 /* " */) {
      inString = true;
      continue;
    }
    if (ch == 0x7B /* { */) {
      depth++;
    } else if (ch == 0x7D /* } */) {
      depth--;
      if (depth == 0) {
        return s.substring(start, i + 1);
      }
      if (depth < 0) {
        // Unbalanced: more closes than opens. Bail.
        return null;
      }
    }
  }
  // Reached end of string without closing the outer brace.
  return null;
}
