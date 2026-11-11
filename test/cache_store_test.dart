// The rules of the offline cache: what it keeps, what it refuses, and what
// it throws away first.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/cache/cache_store.dart';
import 'package:minstrel/cache/device_storage.dart';
import 'package:minstrel_core/minstrel_core.dart';

const mb = 1024 * 1024;

/// A home URL as the proxy serves them: `/h/{home id}/{path the launchpad
/// minted}`. The port varies between runs, which is why the key leaves it out.
Uri homeUrl(String path, {int port = 47380}) =>
    Uri.parse('http://127.0.0.1:$port/h/home1/u/192.168.1.9:9790/$path');

DidlResource res(Uri uri, String mime, {int? bitrate, int? bitsPerSample}) =>
    DidlResource(
      uri: uri,
      protocolInfo: ProtocolInfo.parse('http-get:*:$mime:*'),
      bitrate: bitrate,
      bitsPerSample: bitsPerSample,
      sampleFrequency: 44100,
    );

String didlFor(DidlResource r) => '<DIDL-Lite '
    'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
    '<item id="1" parentID="0" restricted="1"><dc:title>A Track</dc:title>'
    '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
    '<res protocolInfo="http-get:*:${r.mimeType}:*">${r.uri}</res>'
    '</item></DIDL-Lite>';

void main() {
  late Directory root;
  late CacheStore store;
  var space = const StorageSpace(free: 100 * gigabyte, total: 128 * gigabyte);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('minstrel-cache-test');
    space = const StorageSpace(free: 100 * gigabyte, total: 128 * gigabyte);
    store = CacheStore(Directory('${root.path}/cache'), space: () async => space)
      ..budget = 10 * mb;
    await store.load();
  });

  tearDown(() => root.delete(recursive: true));

  /// A freshly fetched file of [size] bytes, as the fetcher would hand it over.
  Future<File> fetched(int size) async {
    final f = File('${root.path}/tmp-${DateTime.now().microsecondsSinceEpoch}');
    await f.writeAsBytes(List.filled(size, 0));
    return f;
  }

  Future<CacheEntry?> keep(String path, int size,
      {String mime = 'audio/flac', int? bitrate, int? bitsPerSample}) async {
    final r = res(homeUrl(path), mime, bitrate: bitrate, bitsPerSample: bitsPerSample);
    return store.adopt(await fetched(size),
        key: CacheStore.keyFor(r.uri)!, resource: r, didl: didlFor(r));
  }

  group('identity', () {
    test('a track is known by the server and path it lives at', () {
      expect(CacheStore.keyFor(homeUrl('a.flac')), '192.168.1.9:9790/a.flac');
    });

    test('the same track reached either way is the same track', () {
      // At home a server is browsed directly; from anywhere else the same
      // server is reached through the launchpad. A track cached at home has
      // to be recognised from a hotel, or the cache never gets used.
      expect(
          CacheStore.keyFor(Uri.parse('http://192.168.1.9:9790/a.flac')),
          CacheStore.keyFor(homeUrl('a.flac')));
    });

    test('the proxy port is not part of it: it changes between runs', () {
      expect(CacheStore.keyFor(homeUrl('a.flac', port: 47380)),
          CacheStore.keyFor(homeUrl('a.flac', port: 51000)));
    });

    test('a query is part of it: some servers name the track there', () {
      expect(CacheStore.keyFor(Uri.parse('http://192.168.1.9:9790/get?id=7')),
          '192.168.1.9:9790/get?id=7');
      expect(CacheStore.keyFor(Uri.parse('http://192.168.1.9:9790/get?id=8')),
          isNot(CacheStore.keyFor(Uri.parse('http://192.168.1.9:9790/get?id=7'))));
    });

    test('a relay URL is somebody else fetching through us, not our copy', () {
      expect(
          CacheStore.keyFor(
              Uri.parse('http://192.168.1.5:47380/r/tok/h/home1/u/192.168.1.9:9790/a.flac')),
          isNull);
    });

    test('our own cached file is not cacheable again', () {
      expect(CacheStore.keyFor(Uri.file('/data/music-cache/3.flac')), isNull);
    });

    test("a home's own API is not music", () {
      expect(CacheStore.keyFor(Uri.parse('http://127.0.0.1:47380/h/home1/api/info')), isNull);
    });
  });

  group('keeping', () {
    test('a fetched file is kept and counted', () async {
      final e = await keep('a.flac', 2 * mb);
      expect(e, isNotNull);
      expect(store.bytes, 2 * mb);
      expect(store.fileOf(e!).existsSync(), isTrue);
      expect(e.file, endsWith('.flac'), reason: 'recognisable on disk');
    });

    test('the metadata survives, so the cache can be listed with no home', () async {
      final e = await keep('a.flac', mb);
      expect(e!.item.title, 'A Track');
    });

    test('nothing is kept while the cache is off', () async {
      store.enabled = false;
      expect(await keep('a.flac', mb), isNull);
      expect(store.bytes, 0);
    });

    test('nothing is kept with no budget', () async {
      store.budget = 0;
      expect(await keep('a.flac', mb), isNull);
    });

    test('nothing is kept once the device is nearly full', () async {
      space = const StorageSpace(free: 2 * gigabyte, total: 128 * gigabyte);
      expect(await keep('a.flac', mb), isNull,
          reason: 'past the brake, the owner is asked to clear space instead');
      expect(store.bytes, 0);
    });

    test('a device that will not say how full it is counts as having room', () async {
      store = CacheStore(Directory('${root.path}/c2'), space: () async => null)
        ..budget = 10 * mb;
      await store.load();
      final r = res(homeUrl('a.flac'), 'audio/flac');
      expect(
          await store.adopt(await fetched(mb),
              key: CacheStore.keyFor(r.uri)!, resource: r, didl: didlFor(r)),
          isNotNull,
          reason: 'a missing platform method should not silently disable the feature');
    });

    test('a file larger than the whole budget is refused', () async {
      expect(await keep('big.flac', 11 * mb), isNull);
      expect(store.bytes, 0);
    });

    test('a refused file is not left behind', () async {
      store.enabled = false;
      final tmp = await fetched(mb);
      final r = res(homeUrl('a.flac'), 'audio/flac');
      await store.adopt(tmp, key: CacheStore.keyFor(r.uri)!, resource: r, didl: didlFor(r));
      expect(tmp.existsSync(), isFalse, reason: 'the caller has nowhere else to put it');
    });
  });

  group('upgrading', () {
    test('a copy no better than the one held is refused', () async {
      await keep('a.flac', 3 * mb);
      expect(await keep('a.flac', 3 * mb), isNull, reason: 'same quality, nothing to gain');
      expect(store.bytes, 3 * mb);
    });

    test('a better copy replaces the one held, and the old file goes', () async {
      final lossy = await keep('a.flac', mb, mime: 'audio/mpeg', bitrate: 40000);
      final old = store.fileOf(lossy!);
      final better = await keep('a.flac', 4 * mb, bitsPerSample: 16);
      expect(better, isNotNull);
      expect(store.bytes, 4 * mb, reason: 'one copy, not two');
      expect(old.existsSync(), isFalse);
    });

    test('a worse copy does not displace a better one', () async {
      await keep('a.flac', 4 * mb, bitsPerSample: 16);
      expect(await keep('a.flac', mb, mime: 'audio/mpeg', bitrate: 40000), isNull);
      expect(store.bytes, 4 * mb);
    });

    test('the fetcher is told what is worth fetching', () async {
      final flac = res(homeUrl('a.flac'), 'audio/flac', bitsPerSample: 16);
      final key = CacheStore.keyFor(flac.uri)!;
      expect(store.wants(key, flac), isTrue, reason: 'nothing held yet');
      await keep('a.flac', mb, bitsPerSample: 16);
      expect(store.wants(key, flac), isFalse);
      expect(store.wants(key, res(homeUrl('a.flac'), 'audio/flac', bitsPerSample: 24)), isTrue);
    });
  });

  group('eviction', () {
    test('the least recently played goes first', () async {
      await keep('a.flac', 4 * mb);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await keep('b.flac', 4 * mb);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      store.touch('192.168.1.9:9790/a.flac'); // a is played again, so b is oldest
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(await keep('c.flac', 4 * mb), isNotNull);
      expect(store.entry('192.168.1.9:9790/b.flac'), isNull, reason: 'b was oldest');
      expect(store.entry('192.168.1.9:9790/a.flac'), isNotNull);
      expect(store.bytes, 8 * mb);
    });

    test('an evicted file is deleted, not just forgotten', () async {
      final a = await keep('a.flac', 6 * mb);
      final file = store.fileOf(a!);
      await keep('b.flac', 6 * mb);
      expect(file.existsSync(), isFalse);
    });

    test('the unpinned entry is evicted around a pin', () async {
      await keep('pinned.flac', 6 * mb);
      await store.setPinned('192.168.1.9:9790/pinned.flac', true);
      await keep('other.flac', 3 * mb);

      // 6 MB pinned + 4 MB new is exactly the budget, so the 3 MB one goes.
      expect(await keep('new.flac', 4 * mb), isNotNull);
      expect(store.entry('192.168.1.9:9790/pinned.flac'), isNotNull);
      expect(store.entry('192.168.1.9:9790/other.flac'), isNull);
      expect(store.bytes, 10 * mb);
    });

    test('a pin that leaves too little room refuses the newcomer', () async {
      await keep('pinned.flac', 6 * mb);
      await store.setPinned('192.168.1.9:9790/pinned.flac', true);
      await keep('other.flac', 3 * mb);

      // Evicting everything evictable leaves 4 MB, and 5 is wanted.
      expect(await keep('new.flac', 5 * mb), isNull);
      expect(store.entry('192.168.1.9:9790/pinned.flac'), isNotNull,
          reason: 'a pin is never given up to make room');
    });

    test('pins filling the budget is worth saying out loud', () async {
      expect(store.pinnedFillBudget, isFalse);
      await keep('a.flac', 9 * mb);
      await store.setPinned('192.168.1.9:9790/a.flac', true);
      expect(store.pinnedBytes, 9 * mb);
      expect(await keep('b.flac', 4 * mb), isNull);
      store.budget = 8 * mb;
      expect(store.pinnedFillBudget, isTrue,
          reason: 'the cache looks broken otherwise');
    });

    test('lowering the budget trims the cache', () async {
      await keep('a.flac', 4 * mb);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await keep('b.flac', 4 * mb);
      store.budget = 5 * mb;
      await store.trim();
      expect(store.bytes, 4 * mb);
      expect(store.entry('192.168.1.9:9790/b.flac'), isNotNull, reason: 'the newer one stays');
    });
  });

  group('standing in for home', () {
    const flacSinks = [ProtocolInfo('http-get', '*', 'audio/flac', '*')];
    const mp3Sinks = [ProtocolInfo('http-get', '*', 'audio/mpeg', '*')];

    test('away from home an equal copy stands in', () async {
      await keep('a.flac', mb, bitsPerSample: 16);
      final wanted = res(homeUrl('a.flac'), 'audio/flac', bitsPerSample: 16);
      expect(store.standIn('192.168.1.9:9790/a.flac', wanted, homeReachable: true), isNotNull);
    });

    test('a worse copy does not: home has better and can be reached', () async {
      await keep('a.flac', mb, mime: 'audio/mpeg', bitrate: 16000);
      final wanted = res(homeUrl('a.flac'), 'audio/flac', bitsPerSample: 24);
      expect(store.standIn('192.168.1.9:9790/a.flac', wanted, homeReachable: true), isNull);
    });

    test('with home out of reach, any copy beats silence', () async {
      await keep('a.flac', mb, mime: 'audio/mpeg', bitrate: 16000);
      final wanted = res(homeUrl('a.flac'), 'audio/flac', bitsPerSample: 24);
      expect(store.standIn('192.168.1.9:9790/a.flac', wanted, homeReachable: false), isNotNull);
    });

    test('nothing held is nothing to play', () {
      final wanted = res(homeUrl('gone.flac'), 'audio/flac');
      expect(store.standIn('192.168.1.9:9790/gone.flac', wanted, homeReachable: false), isNull);
    });

    test('a copy the output cannot play is no stand-in, however good', () async {
      await keep('a.flac', mb, bitsPerSample: 24);
      final wanted = res(homeUrl('a.flac'), 'audio/mpeg', bitrate: 16000);
      expect(
          store.standIn('192.168.1.9:9790/a.flac', wanted,
              homeReachable: false, sinks: mp3Sinks),
          isNull,
          reason: 'a cached FLAC beats an MP3 on quality and is no use to an MP3-only renderer');
      expect(
          store.standIn('192.168.1.9:9790/a.flac', wanted,
              homeReachable: false, sinks: flacSinks),
          isNotNull);
    });
  });

  group('surviving restarts', () {
    test('entries, pins and play order come back', () async {
      await keep('a.flac', 2 * mb);
      await store.setPinned('192.168.1.9:9790/a.flac', true);

      final again = CacheStore(store.dir, space: () async => space)..budget = 10 * mb;
      await again.load();
      expect(again.bytes, 2 * mb);
      final e = again.entry('192.168.1.9:9790/a.flac');
      expect(e, isNotNull);
      expect(e!.pinned, isTrue);
      expect(e.item.title, 'A Track');
      expect(e.resource.mimeType, 'audio/flac');
    });

    test('a file that has gone missing is a miss, and the index heals', () async {
      final e = await keep('a.flac', 2 * mb);
      await store.fileOf(e!).delete(); // storage reclaimed, or a volume unmounted
      expect(store.entry('192.168.1.9:9790/a.flac'), isNull);
      expect(store.bytes, 0, reason: 'it no longer counts against the budget');
    });

    test('files the index cannot name are not left to accumulate', () async {
      await keep('a.flac', 2 * mb);
      final stray = File('${store.dir.path}/99.flac');
      await stray.writeAsBytes(List.filled(mb, 0));
      await File('${store.dir.path}/index.json').delete();

      await store.load();
      expect(stray.existsSync(), isFalse);
      expect(store.bytes, 0);
    });
  });

  group('the owner', () {
    test('turning the cache off empties it, pins included', () async {
      await keep('a.flac', 2 * mb);
      await store.setPinned('192.168.1.9:9790/a.flac', true);
      await keep('b.flac', 2 * mb);

      await store.clear();
      expect(store.bytes, 0);
      expect(store.entries, isEmpty);
      expect(await store.dir.list().where((f) => !f.path.endsWith('index.json')).isEmpty, isTrue);
    });

    test('can free space while keeping what was pinned on purpose', () async {
      await keep('kept.flac', 2 * mb);
      await store.setPinned('192.168.1.9:9790/kept.flac', true);
      await keep('loose.flac', 3 * mb);

      expect(store.unpinnedBytes, 3 * mb);
      expect(await store.clearUnpinned(), 3 * mb);
      expect(store.bytes, 2 * mb);
      expect(store.entry('192.168.1.9:9790/kept.flac'), isNotNull);
      expect(store.entry('192.168.1.9:9790/loose.flac'), isNull);
    });

    test('freeing space when nothing is pinned empties it', () async {
      await keep('a.flac', 2 * mb);
      expect(await store.clearUnpinned(), 2 * mb);
      expect(store.entries, isEmpty);
    });

    test('the files of what was freed are gone, not just forgotten', () async {
      final loose = await keep('loose.flac', 2 * mb);
      final file = store.fileOf(loose!);
      await store.clearUnpinned();
      expect(file.existsSync(), isFalse);
    });

    test('the default budget is a tenth of what is free, in whole gigabytes', () {
      expect(CacheStore.defaultBudget(const StorageSpace(free: 64 * gigabyte, total: 128 * gigabyte)),
          6 * gigabyte);
    });

    test('it rounds down, so it never overcommits a full phone', () {
      expect(CacheStore.defaultBudget(const StorageSpace(free: 29 * gigabyte, total: 128 * gigabyte)),
          2 * gigabyte);
    });

    test('a gigabyte is the floor: a smaller cache only makes warnings', () {
      expect(CacheStore.defaultBudget(const StorageSpace(free: 5 * gigabyte, total: 128 * gigabyte)),
          gigabyte);
    });

    test('with under a gigabyte free the feature starts off', () {
      expect(CacheStore.defaultBudget(const StorageSpace(free: 600 * mb, total: 128 * gigabyte)), 0);
    });
  });
}
