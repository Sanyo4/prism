/// Bridges Android `ComponentCallbacks2.onTrimMemory(RUNNING_LOW+)` into
/// a Dart-side callback so the slice-8 `MobileBackend` can release its
/// resident Cactus model on pressure (slice 8 §2 lifecycle bullet, §10
/// risk 6).
///
/// Flutter normalises every `onTrimMemory` level (5/10/15/20/40/60/80
/// per `ComponentCallbacks2`) into a single
/// `WidgetsBindingObserver.didHaveMemoryPressure()` callback — the
/// platform does NOT pass the integer level through. We therefore
/// treat every pressure event as "release the model"; the slice-8 plan
/// scopes the release pin at `TRIM_MEMORY_RUNNING_LOW` (10), which is
/// the *first* level Android reports for a foreground app, so the
/// over-fire on `RUNNING_MODERATE` (5) is harmless: `releaseModel()`
/// is documented idempotent (slice 8 §7).
///
/// **Decoupling rationale (slice 8 §6 hard rule):** the observer
/// delivers a `void Function()` callback rather than calling
/// `MobileBackend` directly. That keeps this file UI-side only — no
/// `package:prism_llm_mobile` import — and lets `main.dart` route the
/// event into a Riverpod `Notifier` that providers can `listen` to.
/// Linux desktop instantiates the observer too (no harm; the platform
/// never fires `didHaveMemoryPressure` outside Android), so the
/// registration site doesn't need a `Platform.isAndroid` check.
library;

import 'package:flutter/widgets.dart';

/// Registers itself with `WidgetsBinding.instance` and forwards every
/// `didHaveMemoryPressure` callback to [onPressure]. Idempotent on
/// [register] / [unregister] within a single app process.
class MemoryPressureObserver with WidgetsBindingObserver {
  MemoryPressureObserver({required this.onPressure});

  /// Called from inside `didHaveMemoryPressure`. Must be safe to
  /// call repeatedly; downstream consumers debounce / coalesce.
  /// Asynchronous: the observer doesn't await — releases happen on
  /// a separate Riverpod notification path.
  final Future<void> Function() onPressure;

  bool _registered = false;

  /// Adds this observer to `WidgetsBinding.instance`. Safe to call
  /// before `runApp` once `WidgetsFlutterBinding.ensureInitialized()`
  /// has run.
  void register() {
    if (_registered) return;
    WidgetsBinding.instance.addObserver(this);
    _registered = true;
  }

  /// Removes this observer. Tests + hot-restart paths use this; the
  /// production app-process lifecycle is "register at boot, never
  /// unregister".
  void unregister() {
    if (!_registered) return;
    WidgetsBinding.instance.removeObserver(this);
    _registered = false;
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    // Fire-and-forget — the observer never awaits the consumer's work
    // because the framework's contract is "return quickly from this
    // callback or risk an ANR". Errors inside [onPressure] surface as
    // an unhandled future and are caught by the `runZonedGuarded`
    // around `runApp`.
    // ignore: discarded_futures
    onPressure();
  }
}
