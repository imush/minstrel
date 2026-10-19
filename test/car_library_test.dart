import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/car/car_library.dart';
import 'package:minstrel_core/minstrel_core.dart';

String container(String id, String title, {String cls = 'object.container.album.musicAlbum'}) =>
    '<container id="$id" parentID="p"><dc:title>$title</dc:title><upnp:class>$cls</upnp:class></container>';

String track(String id, String title, {String cls = 'object.item.audioItem.musicTrack', String album = 'Album'}) =>
    '<item id="$id" parentID="p"><dc:title>$title</dc:title><upnp:class>$cls</upnp:class>'
    '<upnp:album>$album</upnp:album><upnp:artist>Walter</upnp:artist>'
    '<upnp:albumArtURI>http://192.168.1.9:9790/art/$id.jpg</upnp:albumArtURI>'
    '<res protocolInfo="http-get:*:audio/flac:*">http://192.168.1.9:9790/$id.flac</res></item>';

List<DidlObject> didl(List<String> parts) => parseDidlLite(wrapDidlLite(parts.join()));

class FakeSource implements CarSource {
  final Map<String, List<DidlObject>> tree;
  final searches = <String>[];
  List<DidlObject> albumHits = const [];
  List<DidlObject> trackHits = const [];

  final changesController = StreamController<void>.broadcast();
  List<({String udn, String name, String? via})> list = [(udn: 'uuid:minim', name: 'MinimServer', via: 'Home')];

  FakeSource(this.tree);

  @override
  Stream<void> get changes => changesController.stream;

  @override
  List<({String udn, String name, String? via})> get servers => list;

  @override
  Future<BrowseResult> browse(String udn, String objectId, {int start = 0, int count = 200}) async {
    final all = tree[objectId] ?? const [];
    final page = all.skip(start).take(count).toList();
    return BrowseResult(page, all.length, 1);
  }

  @override
  Future<BrowseResult> search(String udn, String criteria, {int count = 50}) async {
    searches.add(criteria);
    final hits = criteria.contains('container.album') ? albumHits : trackHits;
    return BrowseResult(hits, hits.length, 1);
  }

  @override
  Future<List<DidlItem>> tracks(String udn, String containerId) async =>
      (tree[containerId] ?? const []).whereType<DidlItem>().where((i) => i.isAudio).toList();
}

class FakePlayer implements CarPlayer {
  List<String> played = const [];
  int start = -1;
  bool resumed = false;

  @override
  Future<void> playItems(List<DidlItem> items, int start) async {
    played = [for (final i in items) i.title];
    this.start = start;
  }

  @override
  Future<bool> resume() async => resumed = true;
}

class MemoryHistory implements CarHistoryStore {
  List<String> entries = [];
  @override
  List<String> load() => entries;
  @override
  Future<void> save(List<String> e) async => entries = e;
}

void main() {
  late FakeSource source;
  late FakePlayer player;
  late MemoryHistory history;
  late CarLibrary car;

  setUp(() {
    source = FakeSource({
      '0': didl([
        container('albums', 'Albums', cls: 'object.container.storageFolder'),
        container('photos', 'Photos', cls: 'object.container.album.photoAlbum'),
      ]),
      'albums': didl([container('pastorale', 'Symphony No. 6 | "Pastorale"')]),
      'pastorale': didl([
        track('t1', 'Allegro ma non troppo'),
        track('v1', 'Concert film', cls: 'object.item.videoItem.movie'),
        track('t2', 'Andante molto mosso'),
        track('t3', 'Allegro'),
      ]),
    });
    player = FakePlayer();
    history = MemoryHistory();
    car = CarLibrary(source, player, history);
  });

  test('top level is the library, plus Recent once something was played', () async {
    expect(car.roots().map((n) => n.id), [CarLibrary.library]);
    final servers = await car.children(CarLibrary.library);
    expect(servers.single.title, 'MinimServer');
    expect(servers.single.subtitle, 'via Home');
    expect(servers.single.browsable, isTrue);
  });

  test('browsing shows audio only', () async {
    final server = (await car.children(CarLibrary.library)).single;
    final top = await car.children(server.id);
    expect(top.map((n) => n.title), ['Albums'], reason: 'photo album left out');
    final albums = await car.children(top.single.id);
    expect(albums.single.title, 'Symphony No. 6 | "Pastorale"');
    final tracks = await car.children(albums.single.id);
    expect(tracks.map((n) => n.title), ['Allegro ma non troppo', 'Andante molto mosso', 'Allegro'],
        reason: 'video left out');
    expect(tracks.every((n) => n.playable && !n.browsable), isTrue);
    expect(tracks.first.art, Uri.parse('http://192.168.1.9:9790/art/t1.jpg'));
  });

  test('a track plays its album from that track, and is remembered', () async {
    final album = (await car.children(
            (await car.children((await car.children((await car.children(CarLibrary.library)).single.id)).single.id))
                .single
                .id));
    await car.play(album[1].id);
    expect(player.played, ['Allegro ma non troppo', 'Andante molto mosso', 'Allegro']);
    expect(player.start, 1);

    expect(car.roots().map((n) => n.id), [CarLibrary.history, CarLibrary.library]);
    final recent = await car.children(CarLibrary.history);
    expect(recent.single.title, 'Album');
    expect(recent.single.browsable, isTrue);
    // A remembered folder opens again, ids and all.
    expect((await car.children(recent.single.id)).length, 3);
  });

  test('history keeps the latest first, without repeats', () async {
    await car.remember('u', 'a', 'A', null);
    await car.remember('u', 'b', 'B', null);
    await car.remember('u', 'a', 'A again', null);
    expect((await car.children(CarLibrary.history)).map((n) => n.title), ['A again', 'B']);
  });

  test('pages', () async {
    source.tree['big'] = didl([for (var i = 0; i < 30; i++) track('x$i', 'Track $i')]);
    final page2 = await car.children('c|uuid%3Aminim|big', page: 1, pageSize: 10);
    expect(page2.first.title, 'Track 10');
    expect(page2.length, 10);
  });

  test('search lists albums, then tracks, with quotes escaped', () async {
    source.albumHits = didl([container('pastorale', 'Pastorale')]);
    source.trackHits = didl([track('t2', 'Andante molto mosso'), track('v1', 'Film', cls: 'object.item.videoItem')]);
    final hits = await car.search('Walter "live"');
    expect(hits.map((n) => n.title), ['Pastorale', 'Andante molto mosso']);
    expect(source.searches.first, contains(r'"Walter \"live\""'));
    await car.play(hits.first.id);
    expect(player.played.length, 3, reason: 'album plays whole');
    await car.play(hits.last.id);
    expect(player.played, ['Andante molto mosso'], reason: 'a found track plays alone');
  });

  test('voice: an album if one matches, else tracks, else resume', () async {
    source.albumHits = didl([container('pastorale', 'Pastorale')]);
    await car.playFromSearch('pastorale');
    expect(player.played.length, 3);

    source.albumHits = const [];
    source.trackHits = didl([track('t3', 'Allegro')]);
    await car.playFromSearch('allegro');
    expect(player.played, ['Allegro']);

    await car.playFromSearch('');
    expect(player.resumed, isTrue);
  });

  test('tells the car when servers come and go, and when Recent appears', () async {
    final seen = <String>[];
    car.changed.listen(seen.add);
    source.changesController.add(null); // a renderer, say: no change
    source.list = [...source.list, (udn: 'uuid:b', name: 'B', via: null)];
    source.changesController.add(null);
    await car.remember('u', 'a', 'A', null);
    await car.remember('u', 'b', 'B', null);
    await pumpEventQueue();
    expect(seen, [CarLibrary.library, CarLibrary.top, CarLibrary.history, CarLibrary.history]);
  });

  test('unknown ids are harmless', () async {
    expect(await car.children('nonsense'), isEmpty);
    await car.play('nonsense');
    expect(player.played, isEmpty);
  });
}
