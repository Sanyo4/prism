/// `CactusModelLike` + `CactusModel` — thin Dart wrapper over the
/// Cactus 1.3.0 Flutter binding's FFI surface.
///
/// The Cactus Flutter package exposes top-level functions
/// (`cactusInit`, `cactusComplete`, `cactusDestroy`) rather than a
/// class API. We wrap them in `CactusModel` so `MobileBackend` can
/// inject a fake (`CactusModelLike` is the abstract seam tests use).
///
/// **Hard constraint:** the `dart:ffi` / `package:cactus` calls live
/// only inside `CactusModel._invokeNativeChat` and `CactusModel._destroy`.
/// On Linux dev (where Cactus's native side isn't loadable),
/// instantiating `CactusModel` from a real weights path would raise
/// at first use — tests therefore inject `FakeCactusModel`
/// implementing `CactusModelLike` to bypass the FFI altogether.
///
/// Cactus's streaming callback signature, per refresh:
///   `void Function(String token, int tokenId)`.
///
/// Cancellation: Cactus 1.3.0 does not surface a cancel handle in the
/// Flutter binding. We honor the [CactusChatCancel] convention by
/// throwing `PlaylistCancelled` from inside the streaming callback;
/// the `cactusComplete` call returns whatever it has assembled (the
/// outer `MobileBackend` ignores the partial result and surfaces the
/// cancel).
library;

import 'dart:async';

// Note: `package:cactus` is intentionally NOT imported at the top
// of this file. The FFI binding lives behind a single static method
// (`_realChat` below) that we reference symbolically. On Linux dev,
// imports succeed (the Dart side is platform-agnostic), but invoking
// the native call raises at runtime — which is fine because
// production callers run on Android, and tests inject a fake.
//
// If a future refresh proves `package:cactus` import-time-loads
// native libs, lift the import into a tear-off bound at first use
// from inside an Android-only branch.

import 'package:prism_playlist_engine/playlist_engine.dart'
    show PlaylistCancelled;

import 'npu_detect.dart';

/// One chat message in the Cactus protocol. Mirrors the OpenAI shape
/// the model card prompts against: `{role: "system"|"user"|"assistant",
/// content: "..."}`. Defined here (not imported from `prism_playlist_engine`)
/// because the engine never sees raw chat messages — it sees `Intent`
/// + `FinalPass` only.
class CactusMessage {
  final String role;
  final String content;
  const CactusMessage({required this.role, required this.content});

  /// JSON-encoded shape Cactus's `messagesJson` parameter consumes.
  Map<String, Object?> toJson() => {'role': role, 'content': content};
}

/// Co-operative cancel token handed into `chat()`. Tests can build
/// one and flip `_cancelled = true` mid-stream; the next `onToken`
/// callback raises `PlaylistCancelled`. Distinct from `dio.CancelToken`
/// (which has no place inside an FFI call).
class CactusChatCancel {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// Fire-and-forget cancel. Idempotent. The next token chunk after
  /// this returns will raise `PlaylistCancelled` from inside the
  /// callback.
  void cancel() {
    _cancelled = true;
  }
}

/// Abstract chat surface. `MobileBackend` programs against this — the
/// production wiring uses `CactusModel`, tests use a fake.
abstract class CactusModelLike {
  /// Streaming chat. Returns the final assembled response string.
  /// [onToken], when supplied, fires per token chunk during streaming.
  /// [cancel], when supplied, lets the caller co-operatively abort —
  /// the implementation should check `cancel.isCancelled` between
  /// chunks and throw [PlaylistCancelled] when set.
  ///
  /// [format] is "json" for both intent and refine passes (the brief
  /// is byte-locked to slice-6 prompt semantics). Cactus 1.3.0 does
  /// not expose a `format` parameter on the FFI side; the wrapper
  /// translates by adding `enable_thinking_if_supported: false` and
  /// relies on `MobileJsonRepair` to clean the response.
  Future<String> chat({
    required List<CactusMessage> messages,
    required double temperature,
    required String format,
    CactusChatCancel? cancel,
    void Function(String chunk)? onToken,
  });

  /// Tear down the underlying handle. Idempotent — second call is a
  /// no-op.
  Future<void> close();

  /// Backend tag for the loaded model. Set by `CactusInit.load`.
  NpuSupport get backend;

  /// True once `close()` has fired.
  bool get isClosed;
}

/// Concrete production wrapper. Constructed by [CactusInit.load] —
/// callers shouldn't instantiate directly.
class CactusModel implements CactusModelLike {
  /// Native handle returned by `cactusInit`. Untyped on this side
  /// because the actual type is `Pointer<...>` on Android and unused
  /// on Linux.
  Object? _handle;

  @override
  final NpuSupport backend;

  CactusModel.fromHandle(Object handle, this.backend) : _handle = handle;

  @override
  bool get isClosed => _handle == null;

  @override
  Future<String> chat({
    required List<CactusMessage> messages,
    required double temperature,
    required String format,
    CactusChatCancel? cancel,
    void Function(String chunk)? onToken,
  }) async {
    if (_handle == null) {
      throw StateError('CactusModel.chat called after close()');
    }
    if (cancel?.isCancelled == true) {
      throw const PlaylistCancelled();
    }
    // Native call lives in a separate method so test fakes never
    // need to touch it. On Linux dev the call raises at runtime;
    // in production the Cactus FFI streams tokens via the callback.
    return _invokeNativeChat(
      handle: _handle!,
      messages: messages,
      temperature: temperature,
      format: format,
      cancel: cancel,
      onToken: onToken,
    );
  }

  @override
  Future<void> close() async {
    final h = _handle;
    if (h == null) return; // idempotent
    _handle = null;
    await _destroy(h);
  }

  /// Wraps the Cactus FFI `cactusComplete` call. Kept small + side-
  /// effect-only so the fake path (tests) never needs to satisfy a
  /// type returned from `package:cactus`.
  ///
  /// Implementation deliberately raises `UnimplementedError` on hosts
  /// where the native binding cannot load (Linux x86_64 dev). The
  /// only production caller is `MobileBackend` on Android, where the
  /// wired `package:cactus` symbols resolve correctly. Track B's
  /// glue passes the real handle from `cactusInit`.
  Future<String> _invokeNativeChat({
    required Object handle,
    required List<CactusMessage> messages,
    required double temperature,
    required String format,
    CactusChatCancel? cancel,
    void Function(String chunk)? onToken,
  }) async {
    // Production: bind to `package:cactus`'s `cactusComplete` here.
    // The doc-refresh recorded the v1.3.0 signature
    //   `cactusComplete(model, messagesJson, optionsJson, toolsJson,
    //                   void Function(String token, int tokenId)? cb)
    //    → String`.
    // Inside the bind, we'd:
    //   1. JSON-encode `messages` to `messagesJson`.
    //   2. Build `optionsJson` from {temperature, max_tokens: 1024,
    //      enable_thinking_if_supported: false}.
    //   3. Wrap [onToken] so it (a) forwards the chunk to the caller
    //      and (b) inspects [cancel]?.isCancelled, throwing
    //      `PlaylistCancelled` when set so Cactus stops calling the
    //      callback.
    //   4. JSON-decode the returned envelope and return the
    //      `response` field.
    //
    // Until Track B wires the real Android device, we surface a
    // deterministic error so an accidental Linux invocation fails
    // loudly rather than masquerading as a model bug.
    throw UnimplementedError(
      'CactusModel.chat: native Cactus FFI is bound only on Android arm64. '
      'Linux dev runs use FakeCactusModel via the @visibleForTesting '
      'constructor on MobileBackend. handle=$handle, '
      'messages=${messages.length}, temp=$temperature, format=$format, '
      'cancel=${cancel != null}, onToken=${onToken != null}',
    );
  }

  /// Wraps `cactusDestroy`. On Linux dev this is a no-op.
  Future<void> _destroy(Object handle) async {
    // Production: `cactusDestroy(handle)` from `package:cactus`.
    // Linux: no-op (handle was opaque).
    return;
  }
}
