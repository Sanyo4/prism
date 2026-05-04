import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prism_core/core.dart';
import 'package:prism_metadata/metadata.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import '../backfill/backfill_queue.dart';
import '../backfill/track_patch.dart';
import '../browse/album_view.dart';
import '../browse/artist_view.dart';
import '../browse/genre_view.dart';
import 'library_providers.dart';

/// SharedPreferences keys + read/write helpers for the slice 2 settings
/// section. Listed here (not in a separate module) because the
/// providers below own the parsing and the settings UI is also a thin
/// consumer of the same provider — so there's exactly one source of
/// truth for the keys.
class OnlineMetadataPrefs {
  OnlineMetadataPrefs._();
  static const enabledKey = 'online_metadata.enabled';
  static const contactEmailKey = 'online_metadata.contact_email';
  static const lastfmKeyKey = 'online_metadata.lastfm_api_key';
}

/// Snapshot of the user's online-metadata settings. Mutating happens
/// through [onlineMetadataSettingsProvider]'s notifier so the
/// repository sees changes without explicit re-creation.
final onlineMetadataSettingsProvider =
    NotifierProvider<OnlineMetadataSettingsNotifier, SettingsSnapshot>(
  OnlineMetadataSettingsNotifier.new,
);

class OnlineMetadataSettingsNotifier extends Notifier<SettingsSnapshot> {
  SharedPreferences? _prefs;

  @override
  SettingsSnapshot build() {
    // Kick off the prefs load once; the initial state is the
    // fail-closed default until prefs resolve.
    Future<void>(() async {
      _prefs = await SharedPreferences.getInstance();
      _publish();
    });
    return const SettingsSnapshot(
      enabled: false,
      contactEmail: '',
      lastfmApiKey: null,
    );
  }

  void _publish() {
    final prefs = _prefs;
    if (prefs == null) return;
    state = SettingsSnapshot(
      enabled: prefs.getBool(OnlineMetadataPrefs.enabledKey) ?? false,
      contactEmail:
          prefs.getString(OnlineMetadataPrefs.contactEmailKey) ?? '',
      lastfmApiKey: prefs.getString(OnlineMetadataPrefs.lastfmKeyKey),
    );
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setBool(OnlineMetadataPrefs.enabledKey, enabled);
    _publish();
  }

  Future<void> setContactEmail(String email) async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(OnlineMetadataPrefs.contactEmailKey, email.trim());
    _publish();
  }

  Future<void> setLastfmKey(String? key) async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    if (key == null || key.isEmpty) {
      await prefs.remove(OnlineMetadataPrefs.lastfmKeyKey);
    } else {
      await prefs.setString(OnlineMetadataPrefs.lastfmKeyKey, key);
    }
    _publish();
  }
}

/// Async resolution of the SQLite-backed [MetadataRepository]. Future-
/// scoped so the database opens off the UI thread; widgets watch via
/// `metadataRepositoryProvider.future` and gate on the AsyncValue.
final metadataRepositoryProvider = FutureProvider<MetadataRepository>((ref) async {
  // Resolve a per-platform DatabaseFactory:
  // - Linux desktop → sqflite_common_ffi (sqlite3 native dylib)
  // - Android → sqflite plugin's default factory
  ffi.DatabaseFactory factory;
  if (Platform.isAndroid) {
    factory = sqflite.databaseFactory;
  } else {
    ffi.sqfliteFfiInit();
    factory = ffi.databaseFactoryFfi;
  }
  final supportDir = await getApplicationSupportDirectory();
  final dbPath = p.join(supportDir.path, 'prism.db');
  final db = await MetadataDb.open(factory: factory, path: dbPath);
  ref.onDispose(db.close);

  final settings = ref.watch(onlineMetadataSettingsProvider);
  final userAgent = _userAgent(settings.contactEmail);
  final mb = MbClient(userAgent: userAgent);
  final caa = CaaClient();
  final lastfm = LastfmClient(apiKey: settings.lastfmApiKey);
  final dao = MetadataDao(db);

  return MetadataRepositoryImpl(
    mbClient: mb,
    caaClient: caa,
    lastfmClient: lastfm,
    dao: dao,
    settings: () => ref.read(onlineMetadataSettingsProvider),
  );
});

String _userAgent(String contactEmail) {
  final email = contactEmail.trim().isEmpty ? 'unknown' : contactEmail.trim();
  // Slice 2 hard-codes 0.2.0; bumped per slice as the app evolves.
  return 'Prism/0.2.0 ( $email )';
}

/// Process-singleton BackfillQueue. Created on first watch; lifetime
/// matches the ProviderContainer (i.e. survives screen rotation but
/// not a full app restart).
final backfillQueueProvider = Provider<BackfillQueue?>((ref) {
  final repoAsync = ref.watch(metadataRepositoryProvider);
  return repoAsync.maybeWhen(
    data: (repo) {
      final q = BackfillQueue(repo: repo);
      ref.onDispose(q.dispose);
      return q;
    },
    orElse: () => null,
  );
});

/// Slice-10b §D4 — debounced wrapper around the raw backfill patch stream.
/// Buffers patches over a sliding 200 ms window; emits the merged map exactly
/// once per quiet window. Saves consumers from rebuilding hundreds of times
/// during metadata enrichment (one patch event per online-metadata row, easily
/// 1k+ during a full backfill).
final _debouncedPatchesProvider =
    StreamProvider<Map<String, TrackMetadataPatch>>((ref) {
  final queue = ref.watch(backfillQueueProvider);
  if (queue == null) {
    return Stream.value(const <String, TrackMetadataPatch>{});
  }

  final controller = StreamController<Map<String, TrackMetadataPatch>>();
  final buffer = <String, TrackMetadataPatch>{};
  Timer? flushTimer;

  void flush() {
    if (buffer.isEmpty) return;
    if (controller.isClosed) return;
    controller.add(Map.unmodifiable(buffer));
  }

  final patchSub = queue.stream.listen((patch) {
    buffer[patch.path] = patch.patch; // Latest patch per path wins.
    flushTimer?.cancel();
    flushTimer = Timer(
      const Duration(milliseconds: 200),
      flush,
    );
  });

  ref.onDispose(() {
    patchSub.cancel();
    flushTimer?.cancel();
    controller.close();
  });

  return controller.stream;
});

/// Streams BackfillQueue patches into a `Map<String, TrackMetadataPatch>`
/// keyed by path. Slice 2's merge model is "last patch wins" — the
/// repository never emits a contradicting patch for the same path
/// because re-runs are gated on `track_meta.patched_at == 0`.
final trackPatchProvider =
    NotifierProvider<TrackPatchNotifier, Map<String, TrackMetadataPatch>>(
  TrackPatchNotifier.new,
);

class TrackPatchNotifier
    extends Notifier<Map<String, TrackMetadataPatch>> {
  StreamSubscription<TrackPatch>? _sub;

  @override
  Map<String, TrackMetadataPatch> build() {
    final queue = ref.watch(backfillQueueProvider);
    if (queue != null) {
      _sub?.cancel();
      _sub = queue.stream.listen((p) {
        // Riverpod 3 requires a new map identity to trigger watchers.
        state = {...state, p.path: p.patch};
      });
      ref.onDispose(() => _sub?.cancel());
    }
    return const <String, TrackMetadataPatch>{};
  }
}

/// `tracksProvider` + debounced patches merged into one map keyed by path.
/// Browse providers consume this. The patch merge applies MB-sourced fields
/// *only when the original tag was missing* —
/// `MetadataRepository._mergePatchFromRecording` already enforced that
/// rule, so `_mergeTrack` below trusts the patch and overwrites null
/// fields verbatim.
///
/// Slice-10b §D4 — consumes the debounced patch stream (_debouncedPatchesProvider)
/// to avoid thrashing the downstream providers (albumsProvider, artistsProvider,
/// genreOptionsProvider, etc.) with hundreds of rebuilds per second during
/// metadata enrichment. The debounce buffers patches over a 200 ms sliding window.
final trackWithPatchProvider =
    Provider<AsyncValue<MergedTracks>>((ref) {
  final tracksAsync = ref.watch(tracksProvider);
  final patchesAsync = ref.watch(_debouncedPatchesProvider);
  return tracksAsync.whenData((tracks) {
    final patches = patchesAsync.asData?.value ?? const <String, TrackMetadataPatch>{};
    final merged = <String, Track>{};
    final releaseMbidByPath = <String, String?>{};
    final artistMbidByPath = <String, String?>{};
    final coverByReleaseMbid = <String, String?>{};
    for (final t in tracks) {
      final patch = patches[t.path];
      merged[t.path] = patch == null ? t : _mergeTrack(t, patch);
      if (patch != null) {
        releaseMbidByPath[t.path] = patch.releaseMbid;
        artistMbidByPath[t.path] = patch.artistMbid;
        if (patch.releaseMbid != null && patch.coverUrl != null) {
          coverByReleaseMbid[patch.releaseMbid!] = patch.coverUrl;
        }
      }
    }
    return MergedTracks(
      tracks: merged.values.toList(growable: false),
      releaseMbidByPath: releaseMbidByPath,
      artistMbidByPath: artistMbidByPath,
      coverByReleaseMbid: coverByReleaseMbid,
    );
  });
});

/// Bundle of slices the browse providers want from the merged set.
/// All maps are unmodifiable from the outside via `Map.unmodifiable`
/// — slice 2 keeps mutation centralised in the merger.
class MergedTracks {
  final List<Track> tracks;
  final Map<String, String?> releaseMbidByPath;
  final Map<String, String?> artistMbidByPath;
  final Map<String, String?> coverByReleaseMbid;

  const MergedTracks({
    required this.tracks,
    required this.releaseMbidByPath,
    required this.artistMbidByPath,
    required this.coverByReleaseMbid,
  });

  static const empty = MergedTracks(
    tracks: <Track>[],
    releaseMbidByPath: <String, String?>{},
    artistMbidByPath: <String, String?>{},
    coverByReleaseMbid: <String, String?>{},
  );
}

/// Applies a patch to a Track without overwriting non-null tags.
/// `Track` is immutable; we reconstruct.
Track _mergeTrack(Track t, TrackMetadataPatch p) => Track(
      path: t.path,
      mtimeMs: t.mtimeMs,
      title: t.title ?? p.title,
      artist: t.artist ?? p.artist,
      albumArtist: t.albumArtist ?? p.albumArtist,
      album: t.album ?? p.album,
      genre: t.genre ?? p.genre,
      trackNo: t.trackNo ?? p.trackNo,
      discNo: t.discNo ?? p.discNo,
      year: t.year ?? p.year,
      duration: t.duration,
      replayGainTrackDb: t.replayGainTrackDb,
      replayGainAlbumDb: t.replayGainAlbumDb,
    );

// --- Browse providers --------------------------------------------------

/// Albums view derived from the merged track map.
final albumsProvider = Provider<AsyncValue<List<AlbumView>>>((ref) {
  return ref.watch(trackWithPatchProvider).whenData((m) =>
      indexAlbums(m.tracks, m.releaseMbidByPath, m.coverByReleaseMbid));
});

/// Artists view; depends on `albumsProvider` rather than recomputing
/// the album grouping.
final artistsProvider = Provider<AsyncValue<List<ArtistView>>>((ref) {
  final mergedAsync = ref.watch(trackWithPatchProvider);
  final albumsAsync = ref.watch(albumsProvider);
  return mergedAsync.whenData((m) {
    // `AsyncValue.asData?.value` in Riverpod 3 — `valueOrNull` was
    // dropped in the 3.x rename pass.
    final albums = albumsAsync.asData?.value ?? const <AlbumView>[];
    return indexArtists(m.tracks, albums, m.artistMbidByPath);
  });
});

final genresProvider = Provider<AsyncValue<List<GenreView>>>((ref) {
  return ref
      .watch(trackWithPatchProvider)
      .whenData((m) => indexGenres(m.tracks));
});

// --- Backfill kickoff --------------------------------------------------

/// One-shot listener that runs the backfill the first time
/// `tracksProvider` resolves. Watching this provider somewhere (the
/// app shell on launch) is what activates the queue.
final backfillKickoffProvider = Provider<void>((ref) {
  final queue = ref.watch(backfillQueueProvider);
  final tracksAsync = ref.watch(tracksProvider);
  if (queue == null) return;
  tracksAsync.whenData((tracks) {
    // ignore: discarded_futures — fire-and-forget; queue persists state.
    queue.run(tracks);
  });
});

// --- Backfill progress (slice-10b §C1) --------------------------------

/// Slice-10b §C1 — exposes BackfillQueue's progress stream so the
/// Settings → Online Metadata card can render live progress.
/// Emits `null` when no run is active (queue not yet ready, or
/// between runs).
final backfillProgressProvider =
    StreamProvider<BackfillProgress?>((ref) async* {
  final queue = ref.watch(backfillQueueProvider);
  if (queue == null) {
    yield null;
    return;
  }
  // Re-emit `null` between runs so the card auto-dismisses.
  yield null;
  await for (final progress in queue.progressStream) {
    yield progress;
    if (progress.isDone) {
      // After the done event, emit null so the card animates out.
      yield null;
    }
  }
});

// --- Per-MBID artist info (Last.fm bio + tags) --------------------------

final artistInfoProvider =
    FutureProvider.family<LastfmArtistInfo?, String>((ref, mbid) async {
  final repo = await ref.watch(metadataRepositoryProvider.future);
  return repo.artistInfo(mbid);
});
