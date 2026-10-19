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

    test('moves saved URLs to the current port', () {
      final old = Uri.parse('http://127.0.0.1:1234/h/abc/u/192.168.1.9:9790/a.flac');
      expect(proxy.rehome(old).port, proxy.port);
      final lan = Uri.parse('http://192.168.1.9:9790/a.flac');
      expect(proxy.rehome(lan), lan);
    });
  });
}
