import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';
import '../cache/cache_store.dart';
import '../widgets/cover_art.dart';
import '../widgets/mini_player.dart';
import '../widgets/queue_actions.dart';
import '../widgets/track_info.dart';
import 'browse_page.dart' show ItemTile, playTracks;
import 'settings_page.dart' show formatBytes;

/// What is kept on this phone, grouped by album.
///
/// Shown wherever you are, including at home: the point is to see what you
/// have before you leave, not only once you have left. Behaves like any
/// other listing — the same actions, and the same Now Playing bar — since
/// from here it is just somewhere music is browsed from. Playing still
/// prefers the server while it answers; a copy here is a fallback.
class OfflinePage extends StatefulWidget {
  const OfflinePage({super.key});

  @override
  State<OfflinePage> createState() => _OfflinePageState();
}

class _OfflinePageState extends State<OfflinePage> {
  final _app = AppServices.instance;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([_app.cache, _app.cacheFetcher]),
        builder: (context, _) {
          final albums = _albums(_app.cache.entries);
          final tracks = [
            for (final a in albums)
              for (final (_, item) in a.tracks) item,
          ];
          return Scaffold(
            appBar: AppBar(
              title: const Text('On this device'),
              actions: [
                if (tracks.isNotEmpty) ...[
                  IconButton(
                    tooltip: 'Play all',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => playTracks(context, tracks, 0),
                  ),
                  IconButton(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => showQueueActions(
                      context,
                      title: 'On this device',
                      playNowLabel: 'Play all',
                      tracks: () async => tracks,
                    ),
                  ),
                ],
              ],
            ),
            body: _body(context, albums),
            bottomNavigationBar: const MiniPlayer(),
          );
        },
      );

  Widget _body(BuildContext context, List<_Album> albums) {
    final cache = _app.cache;
    final pending = _app.cacheFetcher.pendingRequests;

    if (albums.isEmpty && pending == 0) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          cache.enabled
              ? 'Nothing here yet. Music you play at home is kept automatically, '
                  'and you can choose an album to keep from its menu.'
              : 'Keeping music on this device is turned off. Turn it on in Settings.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    return ListView(
      children: [
        ListTile(
          dense: true,
          title: Text('${formatBytes(cache.bytes)} of ${formatBytes(cache.budget)}'),
          subtitle: Text([
            '${_count(cache.entries.length, 'track')} in ${_count(albums.length, 'album')}',
            if (cache.pinnedBytes > 0) '${formatBytes(cache.pinnedBytes)} pinned',
          ].join(' · ')),
        ),
        if (pending > 0)
          ListTile(
            leading: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text('Fetching ${_count(pending, 'track')}'),
            subtitle: const Text('Keeps going while Minstrel is open'),
          ),
        const Divider(height: 1),
        for (final album in albums) _AlbumTile(album: album),
      ],
    );
  }

  static String _count(int n, String what) => n == 1 ? '1 $what' : '$n ${what}s';

  /// Groups what is held by album, most recently played first.
  List<_Album> _albums(List<CacheEntry> entries) {
    final byAlbum = <String, _Album>{};
    for (final e in entries) {
      final DidlItem item;
      try {
        item = e.item;
      } on Object {
        continue; // metadata we can no longer read; it still ages out
      }
      final name = item.album ?? item.title;
      byAlbum
          .putIfAbsent(name,
              () => _Album(name, item.artists.firstOrNull?.name ?? '', item.albumArt))
          .tracks
          .add((e, item));
    }
    return byAlbum.values.toList();
  }
}

class _Album {
  final String name;
  final String artist;
  final Uri? art;
  final List<(CacheEntry, DidlItem)> tracks = [];

  _Album(this.name, this.artist, this.art);

  int get bytes => tracks.fold(0, (n, t) => n + t.$1.bytes);
  bool get allPinned => tracks.every((t) => t.$1.pinned);
  List<DidlItem> get items => [for (final (_, item) in tracks) item];
}

class _AlbumTile extends StatelessWidget {
  final _Album album;

  const _AlbumTile({required this.album});

  @override
  Widget build(BuildContext context) => ExpansionTile(
        leading: CoverArt(album.art, size: 40, placeholder: Icons.album),
        // The three dots sit in the title row, so the expand arrow keeps
        // its usual place and the row still looks like it opens.
        title: Row(
          children: [
            Expanded(
              child: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              tooltip: 'More',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.more_vert),
              onPressed: () => showQueueActions(
                context,
                title: album.name,
                playNowLabel: 'Play all',
                playNow: () => playTracks(context, album.items, 0),
                tracks: () async => album.items,
                pinned: album.allPinned,
              ),
            ),
          ],
        ),
        subtitle: Text([
          if (album.artist.isNotEmpty) album.artist,
          '${album.tracks.length} · ${formatBytes(album.bytes)}',
          if (album.allPinned) 'pinned',
        ].join(' · ')),
        children: [
          for (final (index, (entry, item)) in album.tracks.indexed)
            ItemTile(
              item: item,
              onTap: () => playTracks(context, [item], 0),
              onMore: () => showQueueActions(
                context,
                title: item.title,
                playNowLabel: 'Play',
                playNow: () => playTracks(context, [item], 0),
                fromHere: () async => album.items.sublist(index),
                playFromHere: () => playTracks(context, album.items.sublist(index), 0),
                info: () => showTrackInfo(context, item),
                tracks: () async => [item],
                pinned: entry.pinned,
              ),
            ),
        ],
      );
}
