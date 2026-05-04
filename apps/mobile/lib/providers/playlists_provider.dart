import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import 'cache_db_providers.dart';

/// Slice-10b §C2 — list of persisted AI Compose playlists.
/// Re-fetches when invalidated; consumers (Library Playlists tab,
/// AI tab "recent generations" strip) `ref.watch` this.
final playlistsProvider =
    FutureProvider<List<PlaylistRecord>>((ref) async {
  final db = await ref.watch(cacheDbProvider.future);
  return db.playlists.listAll();
});
