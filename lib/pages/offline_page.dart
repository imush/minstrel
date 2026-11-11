import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';
import '../cache/cache_store.dart';
import '../widgets/cover_art.dart';
import 'browse_page.dart' show playTracks;
import 'settings_page.dart' show formatBytes;

/// What is kept on this phone, grouped by album.
///
/// Shown wherever you are, including at home: the point is to see what you
/// have before you leave, not only once you have left. Playing from here
/// still prefers the server while it can be reached — a cached copy is a
/// fallback, not a replacement.
class OfflinePage extends StatefulWidget {
  const OfflinePage({super.key});

  @override
  State<OfflinePage> createState() => _OfflinePageState();
}

class _OfflinePageState extends State<OfflinePage> {
  final _app = AppServices.instance;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('On this phone')),
        body: ListenableBuilder(
          listenable: Listenable.merge([_app.cache, _app.cacheFetcher]),
          builder: (context, _) => _body(context),
        ),
      );

  Widget _body(BuildContext context) {
    final cache = _app.cache;
    final albums = _albums(cache.entries);
    final pending = _app.cacheFetcher.pendingRequests;

    if (albums.isEmpty && pending == 0) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          cache.enabled
              ? 'Nothing here yet. Music you play at home is kept automatically, '
                  'and you can choose an album to keep from its menu.'
              : 'Keeping music on this phone is turned off. Turn it on in Settings.',
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
        for (final album in albums) _AlbumTile(album: album, onChanged: () => setState(() {})),
      ],
    );
  }

  static String _count(int n, String what) => n == 1 ? '1 $what' : '$n ${what}s';

  /// Groups what is held by album, newest listening first.
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
      final group = byAlbum.putIfAbsent(
          name, () => _Album(name, item.artists.firstOrNull?.name ?? '', item.albumArt));
      group.tracks.add((e, item));
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
}

class _AlbumTile extends StatelessWidget {
  final _Album album;
  final VoidCallback onChanged;

  const _AlbumTile({required this.album, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cache = AppServices.instance.cache;
    return ExpansionTile(
      leading: CoverArt(album.art, size: 40, placeholder: Icons.album),
      title: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        if (album.artist.isNotEmpty) album.artist,
        '${album.tracks.length} · ${formatBytes(album.bytes)}',
      ].join(' · ')),
      trailing: IconButton(
        tooltip: album.allPinned ? 'Unpin album' : 'Pin album',
        icon: Icon(album.allPinned ? Icons.push_pin : Icons.push_pin_outlined),
        onPressed: () async {
          final pin = !album.allPinned;
          for (final (entry, _) in album.tracks) {
            await cache.setPinned(entry.key, pin);
          }
          onChanged();
        },
      ),
      children: [
        for (final (index, track) in album.tracks.indexed)
          ListTile(
            dense: true,
            title: Text(track.$2.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${track.$1.resource.formatLabel} · ${formatBytes(track.$1.bytes)}'),
            onTap: () => playTracks(
                context, [for (final (_, item) in album.tracks) item], index),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: track.$1.pinned ? 'Unpin' : 'Pin',
                  icon: Icon(
                      track.$1.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      size: 20),
                  onPressed: () async {
                    await cache.setPinned(track.$1.key, !track.$1.pinned);
                    onChanged();
                  },
                ),
                IconButton(
                  tooltip: 'Remove from this phone',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () async {
                    await cache.remove(track.$1.key);
                    onChanged();
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}
