/// Tiny on/off flag exposed by [QueueService] so the UI layer can
/// toggle radio-mode behaviour without coupling `packages/playback` to
/// `packages/playlist_engine`.
///
/// Slice-5 contract:
///
/// - `radioMode == false` → [QueueService] is byte-identical to
///   slice 1; the flag is purely cosmetic and the 21 slice-1 invariants
///   in `queue_service_test.dart` still pass unchanged.
/// - `radioMode == true` → callers may use [QueueService.appendForRadio]
///   to grow Upcoming without touching PlayNext head; and the UI shows
///   the "RADIO" badge / `SteerChipBar`.
///
/// The flag does **not** alter `advance` / `retreat` / `move` /
/// `removeAt` semantics. Slice-5's `LookaheadManager` rides on top of
/// the slice-1 `currentIndexStream` listener that already drives
/// `advance` — the flag is the seam where the lookahead append can
/// fire; nothing more.
///
/// Why a separate file: `packages/playback` cannot import
/// `package:prism_playlist_engine` (would couple the playback layer to
/// the engine — see slice 5 §"Hard constraints"). So the flag is a
/// plain Dart abstraction here; engine integration happens up-stack in
/// `apps/mobile/lib/providers/radio_providers.dart`.
library;

import 'dart:async';

/// On/off flag with a change stream so consumers (Riverpod providers,
/// stream-driven listeners) can react without polling.
///
/// Implementation note: the [Stream] is a broadcast stream backed by a
/// [StreamController]. Multiple subscribers are fine; no replay of the
/// most-recent value (subscribers query [isOn] for the seed).
class RadioModeFlag {
  RadioModeFlag({bool initial = false}) : _on = initial;

  final StreamController<bool> _controller =
      StreamController<bool>.broadcast();
  bool _on;
  bool _disposed = false;

  /// Current flag state.
  bool get isOn => _on;

  /// Broadcasts each transition. Does **not** replay the seed value;
  /// listeners read [isOn] at subscription time if they need the
  /// current state.
  Stream<bool> get changes => _controller.stream;

  /// Sets the flag. No-op when [on] equals the current value (so we
  /// don't churn listeners on idempotent writes).
  void set(bool on) {
    if (_disposed) return;
    if (_on == on) return;
    _on = on;
    _controller.add(on);
  }

  /// Releases the broadcast controller. Subsequent [set] calls are
  /// no-ops; subsequent [changes] subscriptions get a closed stream.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }
}
