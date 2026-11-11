// What fills the cache: tracks that were actually played, fetched on the
// home network and remembered until the next visit if we are away.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/cache/cache_fetcher.dart';
import 'package:minstrel/cache/cache_store.dart';
import 'package:minstrel/cache/device_storage.dart';
import 'package:minstrel_core/minstrel_core.dart';

const mb = 1024 * 1024;

Uri homeUrl(String path) => Uri.parse('http://127.0.0.1:47380/h/home1/u/192.168.1.9:9790/$path');

DidlResource res(String path, {String mime = 'audio/flac', int? bitsPerSample}) =>
    DidlResource(
      uri: homeUrl(path),
      protocolInfo: ProtocolInfo.parse('http-get:*:$mime:*'),
      bitsPerSample: bitsPerSample,
      sampleFrequency: 44100,
    );

DidlItem item(DidlResource r) => parseDidlLite('<DIDL-Lite '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="1" parentID="0" restricted="1"><dc:title>A Track</dc:title>'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
        '<res protocolInfo="http-get:*:${r.mimeType}:*"'
        '${r.size == null ? '' : ' size="${r.size}"'}>${r.uri}</res>'
        '</item></DIDL-Lite>')
    .whereType<DidlItem>()
    .single;

void main() {
  late Directory root;
  late CacheStore store;
  late HomeProxy proxy;
  late CacheFetcher fetcher;
  var home = true;
  var fetched = <Uri>[];
  var downloadWorks = true;
  var downloadSize = 2 * mb;

  CacheFetcher build() => CacheFetcher(
        store,
        proxy,
        onFreeConnection: (_) => home,
        download: (from, into) async {
          fetched.add(from);
          if (!downloadWorks) return false;
          await into.writeAsBytes(List.filled(downloadSize, 0));
          return true;
        },
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('minstrel-fetch-test');
    proxy = HomeProxy();
    await proxy.start(port: 0);
    home = true;
    fetched = [];
    downloadWorks = true;
    downloadSize = 2 * mb;
    store = CacheStore(Directory('${root.path}/cache'),
        space: () async => const StorageSpace(free: 100 * gigabyte, total: 128 * gigabyte))
      ..budget = 10 * mb;
    await store.load();
    fetcher = build();
    await fetcher.load();
  });

  tearDown(() async {
    fetcher.close();
    await proxy.close();
    await root.delete(recursive: true);
  });

  /// Plays a track, and lets the fetcher finish whatever it started.
  Future<void> play(String path, {String mime = 'audio/flac', int? bits}) async {
    final r = res(path, mime: mime, bitsPerSample: bits);
    fetcher.notePlayed(item(r), r);
    await fetcher.pump();
    await fetcher.saved;
  }

  test('a track that was played is fetched at home', () async {
    await play('a.flac');
    expect(store.entry('192.168.1.9:9790/a.flac'), isNotNull);
    expect(store.bytes, 2 * mb);
    expect(fetcher.wanted, isEmpty);
  });

  test('the fetch goes through this proxy, whatever port the URL remembers', () async {
    await play('a.flac');
    expect(fetched.single.port, proxy.port,
        reason: 'a URL saved in an earlier run names a port that is gone');
  });

  test('away from home it is remembered rather than fetched', () async {
    home = false;
    await play('a.flac');
    expect(fetched, isEmpty, reason: 'an album is not worth somebody\'s mobile data');
    expect(fetcher.wanted.single.key, '192.168.1.9:9790/a.flac');
    expect(store.bytes, 0);
  });

  test('the next visit home collects what was wanted', () async {
    home = false;
    await play('a.flac');
    await play('b.flac');
    expect(store.bytes, 0);

    home = true;
    await fetcher.pump();
    expect(store.entry('192.168.1.9:9790/a.flac'), isNotNull);
    expect(store.entry('192.168.1.9:9790/b.flac'), isNotNull);
    expect(fetcher.wanted, isEmpty);
  });

  test('the newest wish is collected first', () async {
    home = false;
    await play('old.flac');
    await play('new.flac');
    expect(fetcher.wanted.first.key, '192.168.1.9:9790/new.flac');
  });

  test('playing a track again does not queue it twice', () async {
    home = false;
    await play('a.flac');
    await play('a.flac');
    expect(fetcher.wanted, hasLength(1));
  });

  test('what is already held at that quality is not fetched again', () async {
    await play('a.flac', bits: 16);
    fetched.clear();
    await play('a.flac', bits: 16);
    expect(fetched, isEmpty);
  });

  test('a better copy is worth fetching over one already held', () async {
    await play('a.flac', mime: 'audio/mpeg');
    fetched.clear();
    await play('a.flac', bits: 24);
    expect(fetched, hasLength(1));
    expect(store.entry('192.168.1.9:9790/a.flac')!.resource.mimeType, 'audio/flac');
  });

  test('a server on this network is cached too, launchpad or no', () async {
    // Reached directly rather than through a home: somebody's NAS on the
    // LAN. At home this is also how a paired home's own server is browsed.
    final r = DidlResource(
      uri: Uri.parse('http://192.168.1.9:9790/track.flac'),
      protocolInfo: ProtocolInfo.parse('http-get:*:audio/flac:*'),
    );
    fetcher.notePlayed(item(r), r);
    await fetcher.pump();
    expect(store.entry('192.168.1.9:9790/track.flac'), isNotNull);
  });

  test('a relayed URL is not cached: that is somebody else fetching', () async {
    final r = DidlResource(
      uri: Uri.parse('http://192.168.1.5:47380/r/tok/h/home1/u/192.168.1.9:9790/a.flac'),
      protocolInfo: ProtocolInfo.parse('http-get:*:audio/flac:*'),
    );
    fetcher.notePlayed(item(r), r);
    await fetcher.pump();
    expect(fetcher.wanted, isEmpty);
    expect(fetched, isEmpty);
  });

  test('nothing is fetched while the cache is off', () async {
    store.enabled = false;
    await play('a.flac');
    expect(fetched, isEmpty);
  });

  test('nothing is fetched once the device is nearly full', () async {
    store = CacheStore(store.dir,
        space: () async => const StorageSpace(free: gigabyte, total: 128 * gigabyte))
      ..budget = 10 * mb;
    await store.load();
    fetcher = build();
    home = false; // queue it first, so the brake is what stops the fetch
    await play('a.flac');
    home = true;
    await fetcher.pump();
    expect(fetched, isEmpty);
    expect(fetcher.wanted, hasLength(1), reason: 'still wanted once there is room');
  });

  test('downloads that keep failing are eventually given up on', () async {
    home = false;
    await play('bad.flac');
    await play('good.flac');
    downloadWorks = false;
    home = true;
    await fetcher.pump();
    await fetcher.saved;
    expect(store.bytes, 0);
    expect(fetcher.wanted, isEmpty, reason: 'playing them again asks anew');
    expect(fetched, hasLength(2 * CacheFetcher.maxAttempts));
  });

  test('a half-written file is not left where it could look like a hit', () async {
    home = false;
    await play('a.flac');
    downloadWorks = false;
    home = true;
    await fetcher.pump();
    final left = await store.dir
        .list()
        .where((f) => f.uri.pathSegments.last.startsWith('fetching-'))
        .toList();
    expect(left, isEmpty);
  });

  test('what is wanted survives a restart', () async {
    home = false;
    await play('a.flac');

    final again = build();
    await again.load();
    expect(again.wanted.single.key, '192.168.1.9:9790/a.flac');
    expect(again.wanted.single.resource.mimeType, 'audio/flac');
  });

  test('a fetch killed mid-flight is swept up on the next run', () async {
    await store.dir.create(recursive: true);
    final partial = File('${store.dir.path}/fetching-123');
    await partial.writeAsBytes(List.filled(mb, 0));

    await build().load();
    expect(partial.existsSync(), isFalse);
  });

  test('the queue file is not mistaken for a stray and swept', () async {
    home = false;
    await play('a.flac');
    await store.load(); // no index yet, so the stray sweep runs

    final again = build();
    await again.load();
    expect(again.wanted, hasLength(1));
  });

  group('asked for outright', () {
    /// Downloading, as the browse page would: whatever the network.
    Future<({int queued, int waiting, int held, int unplayable})> download(
      List<String> paths, {
      bool pin = false,
      String mime = 'audio/flac',
    }) async {
      final done = fetcher.request(
          [for (final p in paths) item(res(p, mime: mime))], pin: pin);
      await fetcher.pump();
      await fetcher.saved;
      return done;
    }

    test('a download happens away from home too: that is the point', () async {
      home = false; // the hotel the night before the flight
      expect((await download(['a.flac'])).queued, 1);
      expect(store.entry('192.168.1.9:9790/a.flac'), isNotNull);
      expect(fetcher.wanted, isEmpty);
    });

    test('it goes before tracks merely played', () async {
      home = false;
      await play('played.flac');
      await download(['asked.flac']);
      expect(fetched.single.path, endsWith('asked.flac'),
          reason: 'the played one still waits for a network nobody pays for');
      expect(fetcher.wanted.single.key, '192.168.1.9:9790/played.flac');
    });

    test('pinning is asked for at the same time, or not', () async {
      home = false;
      await download(['loose.flac']);
      await download(['kept.flac'], pin: true);
      expect(store.entry('192.168.1.9:9790/loose.flac')!.pinned, isFalse);
      expect(store.entry('192.168.1.9:9790/kept.flac')!.pinned, isTrue);
    });

    test('a track already held can still be pinned', () async {
      await play('a.flac');
      final again = await download(['a.flac'], pin: true);
      expect(again.queued, 0, reason: 'nothing to fetch');
      expect(again.held, 1, reason: 'it is here, which is not the same as nothing');
      expect(store.entry('192.168.1.9:9790/a.flac')!.pinned, isTrue);
    });

    test('asking again for what is still waiting does not count twice', () async {
      // Asked twice before the fetch has had a chance to run. A request
      // ignores the network gate, so pumping between the two would have
      // fetched it and the second would rightly say it is here.
      final first = fetcher.request([item(res('a.flac'))]);
      final second = fetcher.request([item(res('a.flac'))]);
      expect(first.queued, 1);
      expect(second.queued, 0);
      expect(second.waiting, 1, reason: 'it was already asked for');
      expect(fetcher.wanted, hasLength(1), reason: 'and only wanted once');

      await fetcher.pump();
      await fetcher.saved;
      expect(store.entry('192.168.1.9:9790/a.flac'), isNotNull);
      expect(fetched, hasLength(1), reason: 'fetched once, not twice');
    });

    test('a format this device cannot play is said so, not called held', () async {
      // Reported as "already here" once, which was plainly untrue.
      final done = await download(['odd.ra'], mime: 'audio/vnd.rn-realaudio');
      expect(done.unplayable, 1);
      expect(done.held, 0);
      expect(done.queued, 0);
      expect(fetcher.wanted, isEmpty);
    });

    test('a mixed album reports each part of what happened', () async {
      await play('here.flac');
      home = false;
      final done = fetcher.request([
        item(res('here.flac')),
        item(res('new.flac')),
        item(res('odd.ra', mime: 'audio/vnd.rn-realaudio')),
      ]);
      expect(done.held, 1);
      expect(done.queued, 1);
      expect(done.unplayable, 1);
    });

    test('what a download needs is known before it starts', () async {
      final items = [
        for (final p in ['a.flac', 'b.flac'])
          item(DidlResource(
            uri: homeUrl(p),
            protocolInfo: ProtocolInfo.parse('http-get:*:audio/flac:*'),
            size: 3 * mb,
          )),
      ];
      final e = fetcher.estimate(items);
      expect(e.bytes, 6 * mb);
      expect(e.unknown, 0);
      expect(e.room, 10 * mb, reason: 'the whole budget, with nothing pinned');
      expect(e.bytes, lessThan(e.room));
    });

    test('a pin eats into what a download can use', () async {
      await play('pinned.flac');
      await store.setPinned('192.168.1.9:9790/pinned.flac', true);
      expect(fetcher.estimate(const []).room, 8 * mb);
    });

    test('tracks of unknown size are counted apart, not guessed at', () {
      final e = fetcher.estimate([item(res('a.flac'))]);
      expect(e.bytes, 0);
      expect(e.unknown, 1);
    });
  });

  group('giving up', () {
    test('a track that will not come is retried, then dropped', () async {
      downloadWorks = false;
      home = false;
      fetcher.request([item(res('gone.flac'))]);
      await fetcher.pump();
      await fetcher.saved;
      expect(fetched, hasLength(CacheFetcher.maxAttempts));
      expect(fetcher.wanted, isEmpty);
    });

    test('a failure does not stop the ones behind it', () async {
      home = false;
      fetcher.request([item(res('bad.flac')), item(res('good.flac'))]);
      var calls = 0;
      fetcher = CacheFetcher(store, proxy,
          onFreeConnection: (_) => home,
          download: (from, into) async {
            calls++;
            if (from.path.endsWith('bad.flac')) return false;
            await into.writeAsBytes(List.filled(mb, 0));
            return true;
          });
      await fetcher.load();
      fetcher.request([item(res('bad.flac')), item(res('good.flac'))]);
      await fetcher.pump();
      expect(store.entry('192.168.1.9:9790/good.flac'), isNotNull);
      expect(calls, greaterThan(1));
    });
  });

  test('only so many wishes are kept', () async {
    home = false;
    for (var i = 0; i < CacheFetcher.maxWanted + 5; i++) {
      await play('track$i.flac');
    }
    expect(fetcher.wanted, hasLength(CacheFetcher.maxWanted));
    expect(fetcher.wanted.first.key, endsWith('track${CacheFetcher.maxWanted + 4}.flac'));
  });
}
