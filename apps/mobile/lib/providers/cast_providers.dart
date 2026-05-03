import 'dart:async';
import 'dart:io' show InternetAddress, Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_cast/cast.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Slice-9 §6 step 14 / §10 risk 1 / §11 item 14 — Cast / DLNA
/// provider graph for `apps/mobile`. Five concerns:
///
/// 1. [castDiscoveryProvider] streams the live SSDP-discovered DLNA
///    device list. Subscribes to Track A's [Discovery.stream]; pauses
///    when nothing in the UI is listening (so the multicast scanner
///    is silent while the cast sheet is closed).
/// 2. [mediaServerProvider] is the embedded HTTP server hosting
///    `/<sha1>.flac` and `/aac/<sha1>.m4a` for receivers to pull. Lazy
///    — bound on first watch (when the user opens the cast sheet),
///    stopped on last unwatch (cast sheet closed AND no active remote
///    transport). Slice-9 §10 risk 4 + the brief's "don't boot
///    MediaServer at app launch" rule.
/// 3. [transportProvider] holds the active [CastTransport]. Default
///    is the [LocalTransport] over the slice-1 player; the cast sheet
///    swaps it via [TransportNotifier.setTransport]. Single seam for
///    every consumer.
/// 4. [manualIpListProvider] mirrors the persisted manual-IP entries
///    (`prism.cast.manual_ips`). The settings UI reads/writes through
///    this notifier; on app launch the IPs feed
///    [Discovery.probeManual] so a network with multicast blocked
///    still reaches the receiver (§10 risk 1).
/// 5. [verboseSoapLogProvider] persists the slice-9 §11 item 14
///    debug toggle. The UI surfaces it under Settings → Cast & DLNA;
///    Track A's `Soap` reads it on each request.
///
/// Track A symbols this file consumes via `package:prism_cast/cast.dart`:
///   - [Discovery] (broadcast device stream + manual probe)
///   - [DlnaDevice]
///   - [LocalTransport], [CastTransport]
///   - [MediaServer], [IpSelector]
///   - [kHasChromecastSupport] (top-level const)
///
/// If any symbol drifts at integration time, leave a
/// `TODO(slice-9-integration)` marker and adjust the import; consumers
/// stay unchanged.

/// Shared SharedPreferences keys.
const String _kManualIpsKey = 'prism.cast.manual_ips';
const String _kVerboseSoapKey = 'prism.cast.verbose_soap';

/// The single [Discovery] instance used by the cast sheet, settings
/// section, and the manual-IP probe-on-launch hook. The instance owns
/// its own SSDP socket + 5-min refresh timer and is disposed when
/// the provider is unwatched (i.e. when the ProviderContainer tears
/// down).
final discoveryProvider = Provider<Discovery>((ref) {
  final discovery = Discovery();
  ref.onDispose(discovery.dispose);
  return discovery;
});

/// Live DLNA device list. Subscribing triggers the first M-SEARCH
/// (Track A's [Discovery.stream] is `onListen`-driven); cancelling
/// the last subscription stops the 5-min refresh timer. The cast
/// sheet and the settings section both watch this; Riverpod's
/// reference counting handles pause/resume.
final castDiscoveryProvider = StreamProvider<List<DlnaDevice>>((ref) async* {
  final discovery = ref.watch(discoveryProvider);
  yield* discovery.stream;
});

/// Lazy [MediaServer]. Constructed and `start`ed on first watch;
/// disposed on last unwatch. The cast sheet does not watch it
/// directly — instead, the [TransportNotifier]'s DLNA / Chromecast
/// branches pass `await ref.read(mediaServerProvider.future)` into
/// the transport constructor, which keeps the server warm for as
/// long as a remote transport is active.
///
/// Binds on `0.0.0.0` (every interface) but publishes URLs against
/// the LAN-facing IPv4 picked by [IpSelector.pickLanAddress] —
/// matching slice-9 §10 risk 9 (interface changes mid-session) and
/// the receiver's "can it dial me back" requirement.
final mediaServerProvider = FutureProvider<MediaServer>((ref) async {
  final lanIp =
      await IpSelector.pickLanAddress() ?? InternetAddress.loopbackIPv4;
  final server = MediaServer();
  await server.start(
    publicAddress: lanIp,
    bindAddress: InternetAddress.anyIPv4,
  );
  ref.onDispose(server.stop);
  return server;
});

/// Currently-active transport.
///
/// Default is a [LocalTransport] over the slice-1
/// `playbackServiceProvider`'s underlying player — see
/// `playback_providers.dart` for the wiring. The cast sheet swaps
/// transports via [TransportNotifier.setTransport]; a
/// `ref.listen(transportProvider, ...)` inside `playbackServiceProvider`
/// forwards each new transport to [PlaybackService.setTransport]
/// (which carries position + playing flag across the swap).
final transportProvider =
    NotifierProvider<TransportNotifier, CastTransport>(TransportNotifier.new);

/// State holder for [transportProvider]. Pure state container —
/// `playback_providers.dart` listens for changes and dispatches the
/// swap to [PlaybackService] in a separate listener so this file
/// doesn't need to import `playback_providers.dart` (avoids a
/// circular dependency).
///
/// The initial state is supplied by an override in
/// `app.dart` because constructing a [LocalTransport] requires the
/// slice-1 [AudioPlayerPort] from a sibling provider. The default
/// `build()` throws if no override is in place; tests and runtime
/// scopes always override.
class TransportNotifier extends Notifier<CastTransport> {
  @override
  CastTransport build() {
    throw StateError(
      'transportProvider not initialised — override its initial '
      'state via ProviderScope so the default LocalTransport is '
      'wired against the slice-1 AudioPlayerPort. See '
      'apps/mobile/lib/providers/playback_providers.dart.',
    );
  }

  /// Publishes the new active transport. The
  /// `playbackServiceProvider`'s listener handles the actual
  /// `PlaybackService.setTransport` swap — keeping the side-effect
  /// off this notifier avoids a circular import between
  /// `cast_providers.dart` and `playback_providers.dart`.
  void set(CastTransport next) {
    state = next;
  }
}

/// Persisted manual-IP list (slice 9 §10 risk 1, §8 step 16).
final manualIpListProvider =
    AsyncNotifierProvider<ManualIpListNotifier, List<String>>(
  ManualIpListNotifier.new,
);

/// State holder for the manual-IP list. Reads/writes
/// `prism.cast.manual_ips` in [SharedPreferences] as a
/// `List<String>`. Each entry is a literal IPv4 in dotted-quad form
/// — the settings UI validates with `InternetAddress.tryParse(ip)`
/// before adding.
class ManualIpListNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kManualIpsKey) ?? <String>[];
  }

  /// Persists [ip] and adds it to the in-memory list. No-op if [ip]
  /// is already present. Returns `true` on persistence success.
  Future<bool> add(String ip) async {
    final current = await future;
    if (current.contains(ip)) return true;
    final next = <String>[...current, ip];
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setStringList(_kManualIpsKey, next);
    if (ok) {
      state = AsyncData(next);
    }
    return ok;
  }

  /// Removes [ip] from the list and persists the change.
  Future<bool> remove(String ip) async {
    final current = await future;
    if (!current.contains(ip)) return true;
    final next = current.where((e) => e != ip).toList(growable: false);
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setStringList(_kManualIpsKey, next);
    if (ok) {
      state = AsyncData(next);
    }
    return ok;
  }
}

/// Slice-9 §11 item 14 — verbose SOAP log toggle. Persists to
/// SharedPreferences under `prism.cast.verbose_soap`. Default false.
/// Track A's `Soap` reads this on each request via a getter Track B
/// exposes (debug-only path; no UI dependency from
/// `prism_cast` back into `apps/mobile`).
final verboseSoapLogProvider =
    AsyncNotifierProvider<VerboseSoapLogNotifier, bool>(
  VerboseSoapLogNotifier.new,
);

/// State holder for the verbose-SOAP-log toggle.
class VerboseSoapLogNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kVerboseSoapKey) ?? false;
  }

  /// Persists the new toggle state.
  Future<void> set(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVerboseSoapKey, on);
    state = AsyncData(on);
    // TODO(slice-9-integration): Track A may expose a top-level
    // `Soap.verboseLog` setter on the cast package. When it lands,
    // mirror this state into it here so the toggle takes effect
    // without needing every Soap construction site to re-read the
    // preference.
  }
}

/// Probes every persisted manual IP exactly once per app launch.
/// Watched by `app.dart` so the receiver re-appears on the cast
/// sheet immediately after a reboot, even on a multicast-blocked
/// network. Results join the [discoveryProvider]'s device list via
/// Track A's `Discovery.probeManual` — no separate stream merge.
final castProbeManualOnLaunchProvider = FutureProvider<void>((ref) async {
  final ips = await ref.watch(manualIpListProvider.future);
  if (ips.isEmpty) return;
  final discovery = ref.read(discoveryProvider);
  for (final ip in ips) {
    final addr = InternetAddress.tryParse(ip);
    if (addr == null) continue;
    try {
      await discovery.probeManual(addr);
    } on Object {
      // Manual-IP probes are best-effort. A failure surfaces in the
      // settings UI when the user re-tries; we don't surface it on
      // launch because a transient Wi-Fi delay is the most common
      // cause and the next 5-min refresh resolves it.
    }
  }
});

/// `true` when this build can offer Chromecast at all — i.e. Track A
/// linked the Cast Flutter binding (`flutter_chrome_cast`) and we're
/// running on Android. Linux desktop returns false unconditionally
/// (the Cast SDK native lib is Android-only).
///
/// The cast sheet's "Cast devices" section is hidden when this is
/// false. Settings' lossy-Chromecast notice stays visible — it's an
/// informational row, not a control.
bool get castDevicesAvailable => kHasChromecastSupport && Platform.isAndroid;
