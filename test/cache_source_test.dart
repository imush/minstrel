// The offline cache as the car sees it: one more server, holding what is
// already on this device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/cache/cache_store.dart';
import 'package:minstrel/cache/device_storage.dart';
import 'package:minstrel/car/cache_source.dart';
import 'package:minstrel/car/car_library.dart';
import 'package:minstrel_core/minstrel_core.dart';

const mb = 1024 * 1024;

Uri homeUrl(String path) => Uri.parse('http://127.0.0.1:47380/h/home1/u/192.168.1.9:9790/$path');

DidlResource res(Uri uri) => DidlResource(
      uri: uri,
      protocolInfo: ProtocolInfo.parse('http-get:*:audio/flac:*'),
      sampleFrequency: 44100,
    );

String didlFor(
  DidlResource r, {
  required String id,
  required String title,
  required String album,
  required String artist,
  int? track,
}) =>
    '<DIDL-Lite '
    'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
    '<item id="$id" parentID="0" restricted="1"><dc:title>$title</dc:title>'
    '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
    '<upnp:album>$album</upnp:album><upnp:artist>$artist</upnp:artist>'
    '${track == null ? '' : '<upnp:originalTrackNumber>$track</upnp:originalTrackNumber>'}'
    '<res protocolInfo="http-get:*:audio/flac:*">${r.uri}</res>'
    '</item></DIDL-Lite>';

/// A network with no servers on it, so only the cache is left.
class NoServers implements CarSource {
  @override
  List<({String udn, String name, String? via})> get servers => const [];
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<BrowseResult> browse(String udn, String objectId, {int start = 0, int count = 200}) async =>
      const BrowseResult([], 0, 1);
  @override
  Future<LibrarySearchResult> search(String udn, String query) async => LibrarySearchResult.empty;
  @override
  Future<List<DidlItem>> tracks(String udn, String containerId) async => const [];
}

class OneServer extends NoServers {
  @override
  List<({String udn, String name, String? via})> get servers =>
      [(udn: 'uuid:minim', name: 'MinimServer', via: 'Home')];
}

/// A server that is listed but answers nothing: out of signal.
class DeadServer extends OneServer {
  @override
  Future<LibrarySearchResult> search(String udn, String query) async =>
      throw const SocketException('Connection timed out');
}

class MemoryHistory implements CarHistoryStore {
  List<String> entries = [];
  @override
  List<String> load() => entries;
  @override
  Future<void> save(List<String> e) async => entries = e;
}

class SilentPlayer implements CarPlayer {
  List<String> played = const [];
  @override
  Future<void> playItems(List<DidlItem> items, int start) async =>
      played = [for (final i in items) i.title];
  @override
  Future<bool> resume() async => false;
}

void main() {
  late Directory root;
  late CacheStore store;
  late CacheSource source;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('minstrel-car-cache-test');
    store = CacheStore(Directory('${root.path}/cache'),
        space: () async => const StorageSpace(free: 100 * gigabyte, total: 128 * gigabyte))
      ..budget = 10 * mb;
    await store.load();
    source = CacheSource()..attach(store);
  });

  tearDown(() async {
    source.dispose();
    await root.delete(recursive: true);
  });

  Future<void> keep(String file,
      {required String title, required String album, required String artist, int? track}) async {
    final tmp = File('${root.path}/tmp-$file');
    await tmp.writeAsBytes(List.filled(1024, 0));
    final r = res(homeUrl(file));
    await store.adopt(tmp,
        key: CacheStore.keyFor(r.uri)!,
        resource: r,
        didl: didlFor(r, id: file, title: title, album: album, artist: artist, track: track));
  }

  test('an empty cache offers no server at all', () async {
    expect(source.servers, isEmpty);
  });

  test('holding something puts it among the servers', () async {
    await keep('a.flac', title: 'Allegro', album: 'Pastorale', artist: 'Walter');
    expect(source.servers.single.name, 'On this device');
    expect(source.servers.single.via, isNull);
  });

  test('albums list A-Z and their tracks in track order', () async {
    // Added out of order, from two albums, to show neither is incidental.
    await keep('z.flac', title: 'Finale', album: 'Pastorale', artist: 'Walter', track: 3);
    await keep('a.flac', title: 'Allegro', album: 'Pastorale', artist: 'Walter', track: 1);
    await keep('m.flac', title: 'Andante', album: 'Pastorale', artist: 'Walter', track: 2);
    await keep('e.flac', title: 'Adagio', album: 'Eroica', artist: 'Klemperer', track: 1);

    final albums = (await source.browse(CacheSource.udn, CacheSource.root)).objects;
    expect(albums.map((a) => a.title), ['Eroica', 'Pastorale']);
    expect((albums.last as DidlContainer).childCount, 3);

    final tracks = await source.tracks(CacheSource.udn, albums.last.id);
    expect(tracks.map((t) => t.title), ['Allegro', 'Andante', 'Finale']);
  });

  test('a track with no number sorts after the numbered ones', () async {
    await keep('b.flac', title: 'Encore', album: 'Recital', artist: 'Gilels');
    await keep('a.flac', title: 'Sonata', album: 'Recital', artist: 'Gilels', track: 1);
    final album = (await source.browse(CacheSource.udn, CacheSource.root)).objects.single;
    expect((await source.tracks(CacheSource.udn, album.id)).map((t) => t.title),
        ['Sonata', 'Encore']);
  });

  test('search asks no server: it matches title, album and artist', () async {
    await keep('a.flac', title: 'Allegro', album: 'Pastorale', artist: 'Walter');
    await keep('e.flac', title: 'Adagio', album: 'Eroica', artist: 'Klemperer');

    expect((await source.search(CacheSource.udn, 'allegro')).tracks.single.title, 'Allegro');
    expect((await source.search(CacheSource.udn, 'klemperer')).tracks.single.title, 'Adagio');
    expect((await source.search(CacheSource.udn, 'pastor')).albums.single.title, 'Pastorale');
    expect((await source.search(CacheSource.udn, 'sibelius')).isEmpty, isTrue);
  });

  group('merged with the network', () {
    test('servers come first, the cache after', () async {
      await keep('a.flac', title: 'Allegro', album: 'Pastorale', artist: 'Walter');
      final merged = MergedSource(OneServer(), source);
      expect(merged.servers.map((s) => s.name), ['MinimServer', 'On this device']);
    });

    test('each question goes to the source that owns the udn', () async {
      await keep('a.flac', title: 'Allegro', album: 'Pastorale', artist: 'Walter');
      final merged = MergedSource(OneServer(), source);
      expect((await merged.browse(CacheSource.udn, CacheSource.root)).objects, hasLength(1));
      expect((await merged.browse('uuid:minim', '0')).objects, isEmpty);
    });

    test('a spoken request falls through a dead server to the cache', () async {
      await keep('a.flac', title: 'Allegro', album: 'Pastorale', artist: 'Walter', track: 1);
      final player = SilentPlayer();
      final car = CarLibrary(MergedSource(DeadServer(), source), player, MemoryHistory());
      await car.playFromSearch('play allegro');
      expect(player.played, ['Allegro']);
    });

    test('the car can browse it and play from it with no network', () async {
      await keep('a.flac', title: 'Allegro', album: 'Pastorale', artist: 'Walter', track: 1);
      await keep('b.flac', title: 'Andante', album: 'Pastorale', artist: 'Walter', track: 2);
      final player = SilentPlayer();
      final car = CarLibrary(MergedSource(NoServers(), source), player, MemoryHistory());

      final servers = await car.children(CarLibrary.library);
      expect(servers.single.title, 'On this device');
      final albums = await car.children(servers.single.id);
      expect(albums.single.title, 'Pastorale');
      final tracks = await car.children(albums.single.id);
      expect(tracks.map((t) => t.title), ['Allegro', 'Andante']);

      // Pressing the second one plays from there to the end, as anywhere else.
      await car.play(tracks.last.id);
      expect(player.played, ['Andante']);
    });
  });
}
