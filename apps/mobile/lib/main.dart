import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app.dart';
import 'audio/audio_handler.dart';
import 'providers/playback_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // We construct the container up front so the `PrismAudioHandler`
  // closure and the app tree share one [PlaybackService] instance —
  // building the container before `AudioService.init` is intentional.
  // `audio_service` boots a foreground service + channel and then
  // calls the builder once; the handler needs its service ready.
  final container = ProviderContainer();
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

  runApp(UncontrolledProviderScope(
    container: container,
    child: const PrismApp(),
  ));
}
