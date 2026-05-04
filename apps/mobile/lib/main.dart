import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'audio/audio_handler.dart';
import 'audio/memory_pressure_observer.dart';
import 'providers/library_view_prefs.dart';
import 'providers/llm_providers.dart';
import 'providers/llm_providers_mobile.dart';
import 'providers/playback_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Slice 7 — typography is Space Grotesk (matching the design
  // bundle at /tmp/prism-design-extract/...). `google_fonts` fetches
  // the OFL-licensed TTF from fonts.google.com on first launch and
  // caches it on disk; subsequent launches resolve from the cache,
  // never the network. Truly cold-install offline launches fall
  // through to the platform default sans (Roboto / Cantarell) until
  // the cache populates — acceptable per slice 7 §11; slice 8 can
  // bundle the TTFs directly for guaranteed phone-side offline.
  //
  // We leave runtime fetching enabled (the package default) so the
  // first-launch cache populates without a separate setup step.
  GoogleFonts.config.allowRuntimeFetching = true;

  // We construct the container up front so the `PrismAudioHandler`
  // closure and the app tree share one [PlaybackService] instance —
  // building the container before `AudioService.init` is intentional.
  // `audio_service` boots a foreground service + channel and then
  // calls the builder once; the handler needs its service ready.
  //
  // Slice 8 — overrides applied here:
  //
  //   * On Android, `llmBackendProvider` is overridden to read
  //     `mobileBackendProvider.future` and upcast the resulting
  //     `MobileBackend` to `LlmBackend`. The Ollama backend stays
  //     reachable for `cancel()` calls (slice-6 surface) but is
  //     never invoked for generation.
  //   * On Linux desktop the override is omitted; `llmBackendProvider`
  //     defaults to the slice-6 Ollama backend.
  //
  // This is the *only* `Platform.isAndroid` branch in the slice-8
  // platform switch (slice 8 §6 hard rule). Settings → LLM section
  // selection in `settings_screen.dart` and the connectivity-gate
  // text inside `model_download_card.dart` are the documented
  // exceptions.
  final container = ProviderContainer(
    overrides: [
      if (Platform.isAndroid)
        llmBackendProvider.overrideWith((ref) async {
          // `mobileBackendProvider` is `Provider<MobileBackend>`;
          // `MobileBackend implements LlmBackend`, so the upcast is
          // implicit on return. We still wrap in a FutureProvider
          // body because `llmBackendProvider` is itself async (the
          // Linux default reads `ollamaBackendProvider` synchronously
          // but the type stays async-friendly).
          return ref.watch(mobileBackendProvider);
        }),
    ],
  );
  final playback = container.read(playbackServiceProvider);

  await AudioService.init<PrismAudioHandler>(
    builder: () => PrismAudioHandler(playback),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'dev.prism.audio',
      androidNotificationChannelName: 'Prism playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  // Slice 8 — memory-pressure bridge.
  // `MemoryPressureObserver` forwards every Android
  // `ComponentCallbacks2.onTrimMemory(>= RUNNING_LOW)` event into
  // `memoryPressureNotifierProvider`; the slice-8
  // `mobileBackendProvider` listens and calls `releaseModel()`.
  // Linux desktop never fires `didHaveMemoryPressure`, so the
  // observer is inert there — registration is platform-agnostic and
  // the listener inside `mobileBackendProvider` is only built on
  // Android (where the override applies).
  final memoryObserver = MemoryPressureObserver(
    onPressure: () async {
      container.read(memoryPressureNotifierProvider.notifier).fire();
    },
  );
  memoryObserver.register();

  // Android 13 (API 33) made POST_NOTIFICATIONS a runtime permission.
  // Request once; the OS guarantees it only prompts one time — after
  // grant or deny, subsequent calls are silent. iOS / Linux skip this
  // branch entirely. Fire-and-forget: if the user denies we still play
  // audio, only the lockscreen controls go dark (a later slice adds a
  // Settings row to re-prompt).
  //
  // MANAGE_EXTERNAL_STORAGE ("All files access") is required for the
  // dart:io scanner to walk /storage/emulated/0/Music on Android 11+
  // (scoped storage blocks raw File access otherwise). Awaited so the
  // `tracksProvider` FutureProvider — which runs once when the UI
  // mounts — sees a readable root on first scan. The OS opens a
  // dedicated "All files access" settings screen rather than a dialog;
  // the Future resolves when the user returns to the app, regardless
  // of grant status. Denying leaves the app functional but shows an
  // empty track list until the user re-grants. Accepted slice-1
  // trade-off; a later slice will migrate to SAF for Play-Store-safe
  // access.
  if (Platform.isAndroid) {
    // ignore: discarded_futures
    Permission.notification.request();
    await Permission.manageExternalStorage.request();
  }

  // Pre-warm Library prefs so the first build never paints unsorted /
  // unfiltered (spec §7 risk 9). The future resolves before runApp;
  // the sync provider then returns the persisted choice immediately.
  // ignore: unused_result
  await container.read(libraryViewPrefsProvider.future);

  // Spec §7 risk 8 — the album-grouping fix re-keys AlbumView.id
  // between releases for affected albums. Drop any persisted
  // album-detail back-stack entries on first launch after the fix
  // lands so no in-flight Hero observes the id transition.
  final prefs = await SharedPreferences.getInstance();
  const groupingFlag = 'album_grouping_v2_applied';
  if (!(prefs.getBool(groupingFlag) ?? false)) {
    await prefs.setBool(groupingFlag, true);
    // No back-stack to clear before runApp — Flutter restores route
    // stacks lazily; the flag's job here is to record that we ran the
    // gate. Subsequent launches see groupingFlag=true and the new
    // canonical id is the only id ever observed.
  }

  runApp(UncontrolledProviderScope(
    container: container,
    child: const PrismApp(),
  ));
}
