import 'dart:async';

import 'package:minstrel_core/minstrel_core.dart';
import 'package:rxdart/rxdart.dart';

import '../cache/cache_store.dart';
import 'car_library.dart';

/// What is kept on this device, offered to the car as though it were one
/// more server.
///
/// The cache exists for the drive out of signal, so the car is where it
/// matters most; leaving it to the phone's own page meant a driver with a
/// full cache and no bars had nothing to play. It appears beside the real
/// servers rather than as a tab of its own, because to a driver it is
/// simply another place music comes from.
class CacheSource implements CarSource {
  /// Stands where a server's UDN would. Real ones are `uuid:...`, so this
  /// cannot collide with one.
  static const udn = 'cache';

  /// The container holding every album, which is this source's root.
  static const root = '0';

  static const _albumPrefix = 'album:';

  CacheStore? _cache;

  final _changed = BehaviorSubject<void>();

  /// The cache is opened well after the car's menus are wired -- it needs a
  /// directory from the platform -- so this source starts empty and is
  /// given the store when there is one. An empty source lists no server,
  /// which is what should be shown until then anyway.
  void attach(CacheStore cache) {
    _cache?.removeListener(_notify);
    _cache = cache;
    cache.addListener(_notify);
    _notify();
  }

  void _notify() => _changed.add(null);

  @override
  Stream<void> get changes => _changed.stream;

  /// Absent until it holds something: an empty row in the car is one more
  /// thing to read at the wheel and nothing to play.
  @override
  List<({String udn, String name, String? via})> get servers =>
      _items().isEmpty ? const [] : [(udn: udn, name: 'On this device', via: null)];

  @override
  Future<BrowseResult> browse(String udn, String objectId, {int start = 0, int count = 200}) async {
    final all = _children(objectId);
    return BrowseResult(all.skip(start).take(count).toList(), all.length, 1);
  }

  @override
  Future<List<DidlItem>> tracks(String udn, String containerId) async =>
      _children(containerId).whereType<DidlItem>().toList();

  /// Matches what is held, by title, album or artist. No server is asked,
  /// which is the point: this is the one search that works with no signal.
  @override
  Future<LibrarySearchResult> search(String udn, String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return LibrarySearchResult.empty;
    bool hit(String? s) => s != null && s.toLowerCase().contains(q);
    final albums = <DidlContainer>[];
    for (final MapEntry(key: name, value: items) in _byAlbum().entries) {
      if (hit(name) || items.any((i) => i.artists.any((a) => hit(a.name)))) {
        albums.add(_container(name, items));
      }
    }
    return LibrarySearchResult(
      albums: albums,
      tracks: [
        for (final i in _items())
          if (hit(i.title) || hit(i.album) || i.artists.any((a) => hit(a.name))) i,
      ],
    );
  }

  List<DidlObject> _children(String containerId) {
    if (containerId == root) {
      return [for (final MapEntry(key: n, value: i) in _byAlbum().entries) _container(n, i)];
    }
    if (!containerId.startsWith(_albumPrefix)) return const [];
    return _byAlbum()[containerId.substring(_albumPrefix.length)] ?? const [];
  }

  /// Everything held here whose metadata still reads.
  List<DidlItem> _items() {
    final cache = _cache;
    if (cache == null) return const [];
    final out = <DidlItem>[];
    for (final e in cache.entries) {
      try {
        final item = e.item;
        if (item.isAudio) out.add(item);
      } on Object {
        continue; // metadata we can no longer read; it still ages out
      }
    }
    return out;
  }

  /// Held tracks by album, in the order a listing should show them: albums
  /// by name, tracks by track number. Alphabetical rather than
  /// recently-played, because the car offers an A-Z jump down the side and
  /// an order that moves under the driver is worse than one that doesn't.
  Map<String, List<DidlItem>> _byAlbum() {
    final byAlbum = <String, List<DidlItem>>{};
    for (final item in _items()) {
      byAlbum.putIfAbsent(item.album ?? item.title, () => []).add(item);
    }
    for (final items in byAlbum.values) {
      items.sort((a, b) => switch ((a.trackNumber, b.trackNumber)) {
            (final x?, final y?) => x.compareTo(y),
            (null, final _?) => 1,
            (final _?, null) => -1,
            _ => a.title.compareTo(b.title),
          });
    }
    return {
      for (final name in byAlbum.keys.toList()..sort(_byName)) name: byAlbum[name]!,
    };
  }

  static int _byName(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

  DidlContainer _container(String name, List<DidlItem> items) => DidlContainer(
        id: '$_albumPrefix$name',
        parentId: root,
        title: name,
        upnpClass: 'object.container.album.musicAlbum',
        artists: items.first.artists,
        creators: const [],
        album: name,
        genre: items.first.genre,
        date: items.first.date,
        albumArt: items.first.albumArt,
        rawXml: '',
        childCount: items.length,
        searchable: false,
      );

  void dispose() {
    _cache?.removeListener(_notify);
    _changed.close();
  }
}

/// The servers on the network and what is held on this device, as one
/// library. Which source answers is decided by the UDN, so the car's menus
/// need know nothing about either.
class MergedSource implements CarSource {
  final CarSource network;
  final CacheSource local;

  MergedSource(this.network, this.local);

  CarSource _of(String udn) => udn == CacheSource.udn ? local : network;

  /// The cache goes last: a server at home holds the whole library, and
  /// what is on the phone is a corner of it.
  @override
  List<({String udn, String name, String? via})> get servers =>
      [...network.servers, ...local.servers];

  @override
  Stream<void> get changes => Rx.merge([network.changes, local.changes]);

  @override
  Future<BrowseResult> browse(String udn, String objectId, {int start = 0, int count = 200}) =>
      _of(udn).browse(udn, objectId, start: start, count: count);

  @override
  Future<LibrarySearchResult> search(String udn, String query) => _of(udn).search(udn, query);

  @override
  Future<List<DidlItem>> tracks(String udn, String containerId) =>
      _of(udn).tracks(udn, containerId);
}
