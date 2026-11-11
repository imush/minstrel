import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:minstrel_core/minstrel_core.dart';
import 'package:test/test.dart';

// A key made by minstrel-launchpad, and its fingerprint as the launchpad
// printed it.
const fixtureFingerprint = 'v4fpNmRechRp53LQPlMJ7iPFo9WsGdYgpaiwiPVrzuQ';

Uint8List pemToDer(String pem) => base64.decode(pem
    .split('\n')
    .where((l) => l.isNotEmpty && !l.startsWith('-----'))
    .join());

/// A launchpad stand-in: pairing, info, and one audio file, optionally
/// dropping the connection part way through.
class FakeLaunchpad {
  late final HttpServer server;
  final audio = Uint8List.fromList(List.generate(1 << 20, (i) => (i * 7) & 0xff));
  final requests = <HttpRequest>[];
  int dropsLeft = 0;
  int dropAfter = 300000;
  String? token;

  String get address => '127.0.0.1:${server.port}';

  Future<void> start() async {
    final ctx = SecurityContext()
      ..useCertificateChain('test/fixtures/launchpad-cert.pem')
      ..usePrivateKey('test/fixtures/launchpad-key.pem');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    requests.add(req);
    final res = req.response;
    if (req.uri.path == '/api/pair') {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map;
      if (body['code'] != 'goodcode') {
        res.statusCode = 403;
      } else {
        token = 'mlp_secret';
        res.write(jsonEncode({'token': token, 'device': {'id': 'd1', 'name': body['name']}, 'name': 'Test home'}));
      }
      return res.close();
    }
    if (token == null || req.headers.value('authorization') != 'Bearer $token') {
      res.statusCode = req.headers.value('authorization') == null ? 404 : 401;
      return res.close();
    }
    final base = req.headers.value('x-minstrel-base') ?? 'https://${req.headers.host}';
    if (req.uri.path == '/api/info') {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({
        'name': 'Test home',
        'version': 'test',
        'addresses': ['home.example.net:443', address],
        'transcode': ['aac-128', 'aac-192'],
        'servers': [
          {'udn': 'uuid:s1', 'name': 'Music', 'description': '$base/u/192.168.1.9:9791/desc.xml'},
        ],
      }));
      return res.close();
    }
    if (req.uri.path == '/u/192.168.1.9:9790/a.flac') {
      var start = 0, end = audio.length - 1;
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(req.headers.value('range') ?? '');
      if (m != null) {
        start = int.parse(m[1]!);
        if (m[2]!.isNotEmpty) end = int.parse(m[2]!);
        res.statusCode = 206;
        res.headers.set('content-range', 'bytes $start-$end/${audio.length}');
      }
      res.headers
        ..contentType = ContentType('audio', 'flac')
        ..set('accept-ranges', 'bytes');
      res.contentLength = end - start + 1;
      if (dropsLeft > 0) {
        dropsLeft--;
        final socket = await res.detachSocket();
        socket.add(audio.sublist(start, start + dropAfter));
        await socket.flush();
        socket.destroy();
        return;
      }
      res.add(audio.sublist(start, end + 1));
      return res.close();
    }
    if (req.uri.path == '/u/192.168.1.9:9790/c.flac') {
      // A conversion in progress: no length, no ranges, from the start.
      res.headers
        ..contentType = ContentType('audio', 'aac')
        ..set('x-minstrel-transcoded', 'aac-192');
      if (dropsLeft > 0) {
        dropsLeft--;
        // Chunked, as the launchpad sends it, and broken off mid-chunk.
        res.headers.chunkedTransferEncoding = true;
        final socket = await res.detachSocket();
        socket.add(ascii.encode('${dropAfter.toRadixString(16)}\r\n'));
        socket.add(audio.sublist(0, dropAfter));
        socket.add(ascii.encode('\r\n10000\r\n'));
        socket.add(audio.sublist(dropAfter, dropAfter + 1000));
        await socket.flush();
        socket.destroy();
        return;
      }
      res.add(audio);
      return res.close();
    }
    res.statusCode = 404;
    await res.close();
  }
}

void main() {
  test('fingerprint of a launchpad certificate', () {
    final der = pemToDer(File('test/fixtures/launchpad-cert.pem').readAsStringSync());
    expect(spkiFingerprint(der), fixtureFingerprint);
  });

  test('parses pairing links', () {
    final inv = PairingInvitation.parse(
        ' minstrel://pair?v=1&n=My+NAS&fp=abc&c=xyz&a=home.example.net%3A443&a=192.168.1.12%3A7443 ')!;
    expect(inv.name, 'My NAS');
    expect(inv.addresses, ['home.example.net:443', '192.168.1.12:7443']);
    expect(PairingInvitation.parse('https://example.com'), isNull);
    expect(PairingInvitation.parse('minstrel://pair?v=1&fp=abc&c=xyz'), isNull, reason: 'no addresses');

    final relayed = PairingInvitation.parse(
        'minstrel://pair?v=1&fp=abc&c=xyz&a=192.168.1.12%3A7443&r=k3x9abcd.sat.example.org%3A443')!;
    expect(relayed.addresses, ['192.168.1.12:7443']);
    expect(relayed.relays, ['k3x9abcd.sat.example.org:443']);
    expect(PairingInvitation.parse('minstrel://pair?v=1&fp=abc&c=xyz&r=k.sat.example.org%3A443')?.relays,
        ['k.sat.example.org:443'], reason: 'a satellite alone will do');
  });

  test('keeps relay addresses with a home', () {
    const home = Home(
        name: 'H', fingerprint: 'f', token: 't', addresses: ['a:1'], relays: ['r.sat.example.org:443'], deviceId: 'd');
    expect(Home.fromJson(jsonDecode(jsonEncode(home.toJson())) as Map<String, dynamic>).relays, home.relays);
    expect(Home.fromJson({'name': 'H', 'fingerprint': 'f', 'token': 't', 'addresses': ['a:1']}).relays, isEmpty);
  });

  group('with a launchpad', () {
    late FakeLaunchpad lp;
    late HomeProxy proxy;

    setUp(() async {
      lp = FakeLaunchpad();
      await lp.start();
      proxy = HomeProxy(maxOutage: const Duration(seconds: 10));
      await proxy.start(port: 0);
    });

    tearDown(() async {
      await proxy.close();
      await lp.server.close(force: true);
    });

    PairingInvitation invitation({String fp = fixtureFingerprint, String code = 'goodcode'}) =>
        PairingInvitation(name: 'Home', fingerprint: fp, code: code, addresses: ['127.0.0.1:1', lp.address]);

    test('pairs over whichever address answers', () async {
      final home = await pairWithLaunchpad(invitation(), deviceName: 'test phone');
      expect(home.token, 'mlp_secret');
      expect(home.name, 'Test home');
      expect(home.id, fixtureFingerprint.substring(0, 12));
    });

    test('refuses a launchpad with another key', () async {
      await expectLater(pairWithLaunchpad(invitation(fp: 'x' * 43), deviceName: 'p'),
          throwsA(isA<LaunchpadException>().having((e) => e.problem, 'problem', LaunchpadProblem.wrongCertificate)));
      expect(lp.requests.where((r) => r.uri.path == '/api/pair'), isEmpty, reason: 'code never sent');
    });

    test('reports a bad code', () async {
      await expectLater(pairWithLaunchpad(invitation(code: 'nope'), deviceName: 'p'),
          throwsA(isA<LaunchpadException>().having((e) => e.problem, 'problem', LaunchpadProblem.badCode)));
    });

    test('relays with the token and a loopback base', () async {
      final home = await pairWithLaunchpad(invitation(), deviceName: 'p');
      proxy.add(home);
      final info = await proxy.info(home.id);
      expect(info.servers.single.description,
          Uri.parse('http://127.0.0.1:${proxy.port}/h/${home.id}/u/192.168.1.9:9791/desc.xml'));
      expect(proxy.status(home.id).state, HomeState.connected);
      expect(proxy.status(home.id).address, lp.address);

      final url = Uri.parse('${proxy.base(home.id)}/u/192.168.1.9:9790/a.flac');
      expect(HomeProxy.isHomeUrl(url), isTrue);
      final client = HttpClient();
      final rq = await client.getUrl(url);
      rq.headers.set('range', 'bytes=100-199');
      final resp = await rq.close();
      final got = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(resp.statusCode, 206);
      expect(got, lp.audio.sublist(100, 200));
      client.close();
    });

    test('resumes a download when the connection drops', () async {
      final home = await pairWithLaunchpad(invitation(), deviceName: 'p');
      proxy.add(home);
      lp.dropsLeft = 2; // first response and first resume both break
      final client = HttpClient();
      final resp = await (await client.getUrl(Uri.parse('${proxy.base(home.id)}/u/192.168.1.9:9790/a.flac'))).close();
      final got = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(resp.statusCode, 200);
      expect(got.length, lp.audio.length);
      expect(got, lp.audio);
      final ranges = lp.requests.map((r) => r.headers.value('range')).whereType<String>().toList();
      expect(ranges, ['bytes=300000-1048575', 'bytes=600000-1048575']);
      client.close();
    });

    test('resumes a compressed stream, passing over what was played', () async {
      final home = await pairWithLaunchpad(invitation(), deviceName: 'p');
      proxy.add(home);
      lp.dropsLeft = 1;
      final client = HttpClient();
      final resp = await (await client.getUrl(Uri.parse('${proxy.base(home.id)}/u/192.168.1.9:9790/c.flac'))).close();
      final got = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(resp.statusCode, 200);
      expect(got.length, lp.audio.length);
      expect(got, lp.audio);
      client.close();
    });

    test('learns new addresses without dropping the connection', () async {
      final paired = await pairWithLaunchpad(invitation(), deviceName: 'p');
      final home = paired.withAddresses(['127.0.0.1:1', lp.address]);
      proxy.add(home);
      final info = await proxy.info(home.id);
      expect(info.addresses, ['home.example.net:443', lp.address]);
      proxy.update(home.withAddresses(info.addresses));
      expect(proxy.status(home.id).state, HomeState.connected);
      expect((await proxy.info(home.id)).servers, hasLength(1));
    });

    test('says when home is unreachable', () async {
      final home = await pairWithLaunchpad(invitation(), deviceName: 'p');
      proxy.add(Home(
          name: home.name, fingerprint: home.fingerprint, token: home.token, addresses: ['127.0.0.1:1'], deviceId: ''));
      final client = HttpClient();
      final resp = await (await client.getUrl(Uri.parse('${proxy.base(home.id)}/u/192.168.1.9:9790/a.flac'))).close();
      await resp.drain<void>();
      expect(resp.statusCode, 504);
      expect(resp.headers.value('x-launchpad-error'), 'unreachable');
      expect(proxy.status(home.id).state, HomeState.unreachable);
      expect(proxy.status(home.id).tried, [startsWith('127.0.0.1:1 — ')],
          reason: 'says which address failed and how');
      client.close();
    });

    test('prefers a direct address to the satellite', () async {
      lp.token = 'tok';
      final client = pinnedHttpClient(fixtureFingerprint);
      // The same launchpad answers at both; the direct one must win.
      final relay = 'localhost:${lp.server.port}';
      expect(await findLaunchpad(client, [lp.address], relays: [relay], token: 'tok'), lp.address);
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(lp.requests.where((r) => r.headers.host == 'localhost'), isEmpty, reason: 'satellite left alone');
      client.close(force: true);
    });

    test('uses the satellite as soon as the direct addresses fail', () async {
      lp.token = 'tok';
      final client = pinnedHttpClient(fixtureFingerprint);
      final watch = Stopwatch()..start();
      expect(await findLaunchpad(client, ['127.0.0.1:1'], relays: [lp.address], token: 'tok'), lp.address);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 1000)), reason: 'no need to wait out the head start');
      client.close(force: true);
    });

    test('says when it is connected through the satellite', () async {
      final paired = await pairWithLaunchpad(invitation(), deviceName: 'p');
      proxy.add(paired.copyWith(addresses: ['127.0.0.1:1'], relays: [lp.address]));
      await proxy.info(paired.id);
      expect(proxy.status(paired.id).state, HomeState.connected);
      expect(proxy.status(paired.id).viaSatellite, isTrue);
    });

    test('tells IPv6 from IPv4', () {
      // The address in use decides what the Homes list says: a bracketed
      // host is IPv6, which needs no port forwarding at the home end.
      expect(const HomeStatus(HomeState.connected, address: '[2600:db8::1]:7443').isIPv6, isTrue);
      expect(const HomeStatus(HomeState.connected, address: '198.51.100.7:443').isIPv6, isFalse);
      expect(const HomeStatus(HomeState.connected, address: 'myhome.example.net:443').isIPv6, isFalse);
      expect(const HomeStatus(HomeState.connecting).isIPv6, isFalse);
    });

    test('asks the launchpad to compress when set to', () async {
      final home = await pairWithLaunchpad(invitation(), deviceName: 'p');
      proxy.add(home);
      Future<String?> sent() async {
        final client = HttpClient();
        final resp = await (await client.getUrl(Uri.parse('${proxy.base(home.id)}/u/192.168.1.9:9790/a.flac'))).close();
        await resp.drain<void>();
        client.close();
        return lp.requests.last.headers.value('x-minstrel-transcode');
      }

      expect(await sent(), isNull, reason: 'original by default');
      proxy.compression = 'aac-192';
      expect(await sent(), isNull, reason: 'not before the launchpad has said it can');
      await proxy.info(home.id);
      expect(proxy.canCompress(home.id), isTrue);
      expect(await sent(), 'aac-192');
      proxy.compression = 'aac-320';
      expect(await sent(), isNull, reason: 'a profile the launchpad lacks');
    });

    test('lists what happened at each address', () async {
      final inv = PairingInvitation(
          name: 'Home', fingerprint: 'x' * 43, code: 'goodcode', addresses: ['127.0.0.1:1', lp.address]);
      final e = await pairWithLaunchpad(inv, deviceName: 'p').then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<LaunchpadException>());
      final tried = (e! as LaunchpadException).tried;
      expect(tried, hasLength(2));
      expect(tried[0], startsWith('127.0.0.1:1 — '));
      expect(tried[0], isNot(contains('certificate')));
      expect(tried[1], '${lp.address} — answered with a different certificate');
      expect('$e', contains(tried[1]), reason: 'shown with the message');
    });

    group('relaying to a player on the LAN', () {
      late Home home;
      late Uri base;
      late HttpClient client;

      /// Loopback stands in for a LAN address: the relay listener's own
      /// checks are what matters, not which interface it is on.
      setUp(() async {
        home = await pairWithLaunchpad(invitation(), deviceName: 'p');
        proxy.add(home);
        await proxy.info(home.id);
        base = (await proxy.openRelay(InternetAddress.loopbackIPv4))!;
        client = HttpClient();
      });

      tearDown(() => client.close(force: true));

      Uri homeUrl(String path) => Uri.parse('http://127.0.0.1:${proxy.port}/h/${home.id}$path');
      Uri track([String name = 'a.flac']) => homeUrl('/u/192.168.1.9:9790/$name');

      Future<HttpClientResponse> get(Uri u) async => (await client.getUrl(u)).close();

      Future<int> status(Uri u) async {
        final r = await get(u);
        await r.drain<void>();
        return r.statusCode;
      }

      group('serving a copy held on this device', () {
        late Directory dir;
        late File copy;
        // 2600 bytes, each a known value, so a range can be checked exactly.
        final bytes = List<int>.generate(2600, (i) => i % 256);

        setUp(() async {
          dir = await Directory.systemTemp.createTemp('minstrel-copy-test');
          copy = File('${dir.path}/7.flac');
          await copy.writeAsBytes(bytes);
          proxy.localCopies = (name) => name == '7.flac'
              ? LocalCopy(copy, 'audio/flac',
                  source: Uri.parse('http://192.168.1.9:9790/a.flac'))
              : null;
        });

        tearDown(() async {
          proxy.localCopies = null;
          await dir.delete(recursive: true);
        });

        /// A copy URL, queued so the relay will serve it.
        Uri queued() {
          final u = proxy.relayForCopy('7.flac')!;
          proxy.allowRelay([u]);
          return u;
        }

        test('is a relay URL, and says it holds a copy', () {
          final u = proxy.relayForCopy('7.flac')!;
          expect(HomeProxy.isRelayUrl(u), isTrue);
          expect(HomeProxy.isRelayedCopy(u), isTrue);
          expect(HomeProxy.isRelayedCopy(proxy.relayFor(track())!), isFalse);
        });

        test('serves the whole file with no home involved', () async {
          final r = await get(queued());
          expect(r.statusCode, HttpStatus.ok);
          expect(r.contentLength, 2600);
          expect(r.headers.contentType?.mimeType, 'audio/flac');
          expect(r.headers.value(HttpHeaders.acceptRangesHeader), 'bytes',
              reason: 'a player that cannot seek will not try');
          expect(await r.fold<List<int>>([], (a, b) => a..addAll(b)), bytes);
        });

        test('answers a range, which is how a player seeks', () async {
          final req = await client.getUrl(queued());
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
          final r = await req.close();
          expect(r.statusCode, HttpStatus.partialContent);
          expect(r.headers.value(HttpHeaders.contentRangeHeader), 'bytes 100-199/2600');
          expect(r.contentLength, 100);
          expect(await r.fold<List<int>>([], (a, b) => a..addAll(b)),
              bytes.sublist(100, 200));
        });

        test('an open-ended range runs to the end', () async {
          final req = await client.getUrl(queued());
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=2500-');
          final r = await req.close();
          expect(r.statusCode, HttpStatus.partialContent);
          expect(r.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2500-2599/2600');
          expect(await r.fold<List<int>>([], (a, b) => a..addAll(b)), bytes.sublist(2500));
        });

        test('a suffix range gives the last bytes', () async {
          final req = await client.getUrl(queued());
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=-100');
          final r = await req.close();
          expect(r.statusCode, HttpStatus.partialContent);
          expect(r.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2500-2599/2600');
          expect(await r.fold<List<int>>([], (a, b) => a..addAll(b)), bytes.sublist(2500));
        });

        test('a range past the end is clamped, not refused', () async {
          final req = await client.getUrl(queued());
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=2000-99999');
          final r = await req.close();
          expect(r.statusCode, HttpStatus.partialContent);
          expect(r.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2000-2599/2600');
          await r.drain<void>();
        });

        test('a range starting past the end is refused properly', () async {
          final req = await client.getUrl(queued());
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=9999-');
          final r = await req.close();
          expect(r.statusCode, HttpStatus.requestedRangeNotSatisfiable);
          expect(r.headers.value(HttpHeaders.contentRangeHeader), 'bytes */2600');
          await r.drain<void>();
        });

        test('a range it cannot parse is served whole rather than failed', () async {
          final req = await client.getUrl(queued());
          req.headers.set(HttpHeaders.rangeHeader, 'rows=1-2');
          final r = await req.close();
          expect(r.statusCode, HttpStatus.ok);
          await r.drain<void>();
        });

        test('HEAD tells the length without the bytes', () async {
          final r = await (await client.headUrl(queued())).close();
          expect(r.statusCode, HttpStatus.ok);
          expect(r.contentLength, 2600);
          expect(await r.isEmpty, isTrue);
        });

        test('a copy that is not queued is not served', () async {
          final u = proxy.relayForCopy('7.flac')!;
          proxy.allowRelay(const []);
          expect(await status(u), HttpStatus.notFound);
        });

        test('a copy the cache no longer holds is a plain 404', () async {
          final u = queued();
          await copy.delete();
          expect(await status(u), HttpStatus.notFound);
        });

        test('a copy name the cache does not know is a plain 404', () async {
          final u = proxy.relayForCopy('../../etc/passwd')!;
          proxy.allowRelay([u]);
          expect(await status(u), HttpStatus.notFound,
              reason: 'only names the cache itself hands back are served');
        });

        test('a saved queue naming a copy comes back naming the server', () async {
          // The token and the network are both gone by the next run, and
          // the cache may no longer hold it, so it is resolved afresh.
          expect(proxy.rehome(proxy.relayForCopy('7.flac')!),
              Uri.parse('http://192.168.1.9:9790/a.flac'));
        });

        test('a saved copy the cache has dropped is left alone, not mangled', () async {
          final gone = proxy.relayForCopy('404.flac')!;
          expect(proxy.rehome(gone), gone);
        });

        test('copies are not served on the loopback listener', () async {
          proxy.allowRelay([proxy.relayForCopy('7.flac')!]);
          expect(await status(Uri.parse('http://127.0.0.1:${proxy.port}/c/7.flac')),
              HttpStatus.notFound);
        });
      });

      test('serves a queued track to whoever asks, with the token', () async {
        final relayed = proxy.relayFor(track())!;
        expect(HomeProxy.isRelayUrl(relayed), isTrue);
        expect(relayed.toString(), startsWith(base.toString()));
        proxy.allowRelay([relayed]);

        final r = await get(relayed);
        expect(r.statusCode, 200);
        expect(r.headers.contentType.toString(), 'audio/flac');
        expect(await r.fold<int>(0, (n, b) => n + b.length), lp.audio.length);
      });

      test('counts what a player actually fetched', () async {
        final relayed = proxy.relayFor(track())!;
        proxy.allowRelay([relayed]);
        expect(proxy.relayServed, 0);
        await (await get(relayed)).drain<void>();
        expect(proxy.relayServed, 1);
        // Refusals don't count: a player that never gets past the door has
        // not reached us, which is the thing being measured.
        await status(proxy.relayFor(track('c.flac'))!);
        expect(proxy.relayServed, 1);
      });

      test('a wrong token gets the same bare 404 as nothing at all', () async {
        final relayed = proxy.relayFor(track())!;
        proxy.allowRelay([relayed]);
        final wrong = Uri.parse(relayed.toString().replaceFirst(RegExp('/r/[^/]+/'), '/r/notthetoken/'));
        expect(await status(wrong), 404);
      });

      test('serves only what is queued', () async {
        proxy.allowRelay([proxy.relayFor(track())!]);
        expect(await status(proxy.relayFor(track('c.flac'))!), 404,
            reason: 'a track in the library but not in the queue');
        expect(await status(proxy.relayFor(homeUrl('/api/info'))!), 404,
            reason: 'the launchpad API is not the renderer business');
      });

      test('follows the queue as it changes', () async {
        proxy.allowRelay([proxy.relayFor(track())!]);
        expect(await status(proxy.relayFor(track())!), 200);
        proxy.allowRelay([proxy.relayFor(track('c.flac'))!]);
        expect(await status(proxy.relayFor(track())!), 404, reason: 'no longer queued');
      });

      test('reads only: no writes from the network', () async {
        final relayed = proxy.relayFor(track())!;
        proxy.allowRelay([relayed]);
        final r = await (await client.postUrl(relayed)).close();
        await r.drain<void>();
        expect(r.statusCode, 405);
      });

      test('each session gets its own token', () async {
        final again = (await proxy.openRelay(InternetAddress.loopbackIPv4))!;
        expect(again.pathSegments[1], isNot(base.pathSegments[1]));
      });

      test('a closed relay hands out no more URLs', () async {
        await proxy.closeRelay();
        expect(proxy.relaying, isFalse);
        expect(proxy.relayFor(track()), isNull);
      });

      test('never compresses for a player, only for this device', () async {
        proxy.compression = 'aac-192';
        final relayed = proxy.relayFor(track())!;
        proxy.allowRelay([relayed]);
        await (await get(relayed)).drain<void>();
        expect(lp.requests.last.headers.value('x-minstrel-transcode'), isNull,
            reason: 'the metadata the player got says FLAC; AAC under that label is rejected');
        await (await get(track())).drain<void>();
        expect(lp.requests.last.headers.value('x-minstrel-transcode'), 'aac-192');
      });

      test('a saved relay URL comes back as a loopback one', () {
        final relayed = proxy.relayFor(track())!;
        expect(proxy.rehome(relayed), track(), reason: 'its token and address are long gone');
      });
    });

    test('picks this device\'s address on the player\'s network', () {
      final wifi = InternetAddress('192.168.1.12');
      final cellular = InternetAddress('10.172.44.8');
      final vpn = InternetAddress('100.64.3.9');
      final player = InternetAddress('192.168.1.178');
      expect(addressNearest(player, [cellular, wifi, vpn]), wifi);
      // A bigger LAN than /24: still the right side.
      expect(addressNearest(InternetAddress('192.168.9.4'), [cellular, wifi]), wifi);
      // Nothing near it at all: better to say so than to offer an address
      // the player can't reach.
      expect(addressNearest(InternetAddress('203.0.113.5'), [cellular, wifi, vpn]), isNull);
      expect(addressNearest(player, [InternetAddress.loopbackIPv4]), isNull);
      expect(addressNearest(InternetAddress('::1'), [wifi]), isNull);
    });

    test('tells a home address from one reached from outside', () async {
      expect(await isLocalAddress('192.168.1.22:7443'), isTrue);
      expect(await isLocalAddress('10.0.0.5:7443'), isTrue);
      expect(await isLocalAddress('172.20.1.1:7443'), isTrue);
      expect(await isLocalAddress('172.32.1.1:7443'), isFalse, reason: 'outside 172.16/12');
      expect(await isLocalAddress('gw.example.net:7443'), isFalse);
      // IPv6 that can only be local.
      expect(await isLocalAddress('[fd12:3456::1]:7443'), isTrue, reason: 'unique local');
      expect(await isLocalAddress('[fe80::1]:7443'), isTrue, reason: 'link-local');
      // A global IPv6 address this device shares no prefix with is outside.
      // The same address from inside the home is local, which is why this
      // is measured against the device's own addresses rather than parsed.
      expect(await isLocalAddress('[2001:db8:dead:beef::1]:7443'), isFalse);
    });

    test('moves saved URLs to the current port', () {
      final old = Uri.parse('http://127.0.0.1:1234/h/abc/u/192.168.1.9:9790/a.flac');
      expect(proxy.rehome(old).port, proxy.port);
      final lan = Uri.parse('http://192.168.1.9:9790/a.flac');
      expect(proxy.rehome(lan), lan);
    });
  });
}
