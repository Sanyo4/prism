/// `IdleReleaser` — debounced 5-minute idle timer that emits
/// `shouldRelease` when the model has been silent long enough to
/// safely release.
///
/// Slice-8 §10 risk 12 underwrites the contract: `touch()` is called
/// at every `MobileBackend.chat()` entry AND on every `onToken`
/// callback so a 30-second generation doesn't trigger a mid-flight
/// release. Multi-listener safe (broadcast stream — `LlmProgressCard`
/// + the providers may both subscribe).
library;

import 'dart:async';

class IdleReleaser {
  /// How long after the last `touch()` before `shouldRelease` fires.
  /// Default 5 min per slice-8 §1 / §10 risk 12.
  final Duration idle;

  IdleReleaser({this.idle = const Duration(minutes: 5)});

  /// Latest scheduled timer. `touch()` cancels and replaces.
  Timer? _timer;

  /// Broadcast emit point. Multi-listener safe; events are `void`
  /// (the consumer's reaction is "release the model now").
  final StreamController<void> _ctrl = StreamController<void>.broadcast();

  /// True after `dispose()`. Subsequent `touch()` calls are no-ops.
  bool _disposed = false;

  /// Reset the idle timer. Call on every chat entry + every token
  /// chunk. Cheap (cancels & re-schedules a single Timer).
  void touch() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(idle, () {
      if (_disposed || _ctrl.isClosed) return;
      _ctrl.add(null);
    });
  }

  /// Stream of "the model has been idle for [idle] — release it"
  /// events. Broadcast — multiple listeners safe.
  Stream<void> get shouldRelease => _ctrl.stream;

  /// True iff a timer is currently armed. Useful for tests; not part
  /// of the documented API.
  bool get isArmed => _timer?.isActive ?? false;

  /// Tear down. Cancels the timer and closes the controller.
  /// Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (!_ctrl.isClosed) {
      _ctrl.close();
    }
  }
}
