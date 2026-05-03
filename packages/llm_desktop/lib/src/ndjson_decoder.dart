import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Decodes a `Stream<Uint8List>` of newline-delimited JSON
/// (`application/x-ndjson` per Ollama's streaming endpoints) into a
/// `Stream<Map<String, Object?>>`, one event per ndjson line.
///
/// Composition (in order):
/// 1. `utf8.decoder` — accumulates bytes across chunks so multi-byte
///    UTF-8 sequences split mid-chunk decode correctly.
/// 2. `LineSplitter` — accumulates partial lines; emits when a `\n`
///    is seen. Track-B doc-refresh §4 confirms Ollama emits one
///    object per line and may chunk arbitrarily.
/// 3. Per-line `jsonDecode`. Empty / whitespace-only lines are
///    skipped (some daemons emit a trailing blank).
///
/// The transformer is stateful per binding (each `bind` call yields a
/// fresh `StreamSubscription`); callers must not bind the same
/// instance twice on overlapping streams. We hand-roll the binding
/// rather than `StreamTransformer.fromBind` so we can hold one shared
/// pipe-down `StreamController` per bind without leaking state.
class NdjsonDecoder
    extends StreamTransformerBase<Uint8List, Map<String, Object?>> {
  const NdjsonDecoder();

  @override
  Stream<Map<String, Object?>> bind(Stream<Uint8List> stream) {
    final ctrl = StreamController<Map<String, Object?>>(sync: false);
    late final StreamSubscription<String> sub;

    // utf8.decoder is a Converter; use its `bind` to adapt a
    // Stream<List<int>>. Uint8List <: List<int>, but the
    // transformer signature wants exactly List<int>; .cast<List<int>>()
    // is free at runtime.
    final byteStream = stream.cast<List<int>>();
    final lines =
        const LineSplitter().bind(utf8.decoder.bind(byteStream));

    sub = lines.listen(
      (line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        try {
          final obj = jsonDecode(trimmed);
          if (obj is Map<String, Object?>) {
            ctrl.add(obj);
          } else if (obj is Map) {
            // Some daemons return Map<dynamic, dynamic>; coerce
            // defensively so downstream consumers see one type.
            ctrl.add(Map<String, Object?>.from(obj));
          } else {
            ctrl.addError(
              FormatException(
                'ndjson line decoded to ${obj.runtimeType}, expected Map',
                trimmed,
              ),
            );
          }
        } on FormatException catch (e, st) {
          ctrl.addError(e, st);
        }
      },
      onError: ctrl.addError,
      onDone: () async {
        await ctrl.close();
      },
      cancelOnError: false,
    );

    ctrl.onCancel = () async {
      await sub.cancel();
    };
    ctrl.onPause = sub.pause;
    ctrl.onResume = sub.resume;

    return ctrl.stream;
  }
}
