import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:minstrel_core/minstrel_core.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Uri description;
  late DeviceRegistry registry;

  setUp(() async {
    // A UDN of its own, so the real MinimServer on a developer's LAN, found
    // by the registry's own search, isn't taken for this one.
    final xml = File('test/fixtures/minimserver-device.xml')
        .readAsStringSync()
        .replaceAll('f6417dbf-cc85-4560-aa2e-72bbc55f770e', '00000000-0000-4000-8000-000000000001');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      r.response.headers.contentType = ContentType('text', 'xml');
      r.response
        ..write(xml)
        ..close();
    });
    description = Uri.parse('http://127.0.0.1:${server.port}/device.xml');
    registry = DeviceRegistry(http.Client());
  });

  tearDown(() async {
    await registry.dispose();
    await server.close(force: true);
  });

  bool listed() => registry.servers.any((s) => s.udn == 'uuid:00000000-0000-4000-8000-000000000001');

  Future<void> waitUntilListed() async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!listed() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('lists a remembered device without its answering a search', () async {
    registry.remember([Uri.parse('http://127.0.0.1:1/gone.xml'), description]);
    await registry.start();
    await waitUntilListed();
    expect(listed(), isTrue);
  });

  test('keeps devices it finds for the next start', () async {
    final saved = <List<Uri>>[];
    registry
      ..remember([description])
      ..onRemembered = saved.add;
    await registry.start();
    await waitUntilListed();
    // Found again: already kept, so nothing new to save for it. Devices
    // on a developer's LAN may be saved, after it.
    expect(saved.every((l) => l.first == description), isTrue);
  });

  group('a home whose servers do not answer', () {
    // The failure used to be swallowed: a home would connect, list nothing,
    // and say nothing about why.
    test('says which server failed and what happened', () async {
      final dead = Uri.parse('http://127.0.0.1:1/h/abc/u/192.168.1.9:9791/device.xml');
      final problems = await registry.setHomeServers('abc', 'Home', [dead]);

      expect(problems, hasLength(1));
      expect(problems.single.server, '192.168.1.9:9791',
          reason: 'named as the launchpad knows it, not as a loopback URL');
      expect(problems.single.error, isNotEmpty);
      expect(problems.single.toString(), startsWith('192.168.1.9:9791: '));
      expect(registry.homeServers('abc'), isEmpty);
    });

    test('a server that answers leaves nothing to explain', () async {
      final problems = await registry.setHomeServers('abc', 'Home', [description]);
      expect(problems, isEmpty);
      expect(registry.homeServers('abc'), isNotEmpty);
    });

    test('one of two failing is reported while the other still works', () async {
      final dead = Uri.parse('http://127.0.0.1:1/h/abc/u/192.168.1.23:49152/desc.xml');
      final problems = await registry.setHomeServers('abc', 'Home', [description, dead]);
      expect(problems, hasLength(1));
      expect(problems.single.server, '192.168.1.23:49152');
      expect(registry.homeServers('abc'), hasLength(1),
          reason: 'the one that answered is still usable');
    });

    test('an error is one line, short enough to show', () async {
      final problems = await registry.setHomeServers(
          'abc', 'Home', [Uri.parse('http://127.0.0.1:1/h/abc/u/s/device.xml')]);
      expect(problems.single.error, isNot(contains('\n')));
      expect(problems.single.error.length, lessThanOrEqualTo(120));
    });
  });
}
