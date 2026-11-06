import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:minstrel/playback/relay.dart';

void main() {
  late HomeProxy proxy;
  late Set<String> here;

  /// Loopback stands in for the phone's Wi-Fi address, so its subnet is
  /// `127.0.0`. [here] is what the device can see from moment to moment.
  Relay build({Duration grace = const Duration(milliseconds: 20)}) => Relay(
        proxy,
        grace: grace,
        subnets: () async => here,
        addressToward: (_) async => InternetAddress.loopbackIPv4,
      );

  final renderer = Uri.parse('http://127.0.0.1:1/desc.xml');
  final homeUrl = Uri.parse('http://127.0.0.1:1/h/abc/u/192.168.1.9:9790/a.flac');

  setUp(() async {
    proxy = HomeProxy();
    await proxy.start(port: 0);
    here = {'127.0.0'};
  });

  tearDown(() => proxy.close());

  test('nothing is served until the user says so', () async {
    final relay = build();
    expect(relay.allowed, isFalse);
    expect(relay.urlFor(homeUrl), isNull);
    expect(proxy.relaying, isFalse);
  });

  test('granting opens a listener on this network', () async {
    final relay = build();
    expect(await relay.allow(renderer), isTrue);
    expect(relay.allowed, isTrue);
    expect(relay.network, '127.0.0.0/24');
    expect(proxy.relaying, isTrue);
    final url = relay.urlFor(homeUrl)!;
    expect(HomeProxy.isRelayUrl(url), isTrue);
  });

  test('moving to another network takes the permission away', () async {
    final relay = build();
    await relay.allow(renderer);
    here = {'192.168.7'};
    await relay.recheck();
    // Not at once: the grace window is there so a blip doesn't end an album.
    expect(relay.allowed, isTrue, reason: 'still inside the grace window');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(relay.allowed, isFalse);
    expect(proxy.relaying, isFalse, reason: 'the listener is gone too');
    expect(relay.urlFor(homeUrl), isNull);
  });

  test('a blip on the same network keeps it', () async {
    final relay = build();
    await relay.allow(renderer);
    here = const {};
    await relay.recheck();
    here = {'127.0.0'};
    await relay.recheck();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(relay.allowed, isTrue, reason: 'it came back before the window closed');
  });

  test('a rotating IPv6 address is no reason to drop it', () async {
    final relay = build();
    await relay.allow(renderer);
    // Android rotates temporary IPv6 addresses; only IPv4 subnets are
    // compared, so the set the relay looks at hasn't changed.
    await relay.recheck();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(relay.allowed, isTrue);
  });

  test('being unable to look is no reason to drop it either', () async {
    final relay = Relay(
      proxy,
      grace: const Duration(milliseconds: 20),
      subnets: () async => throw const SocketException('no interfaces'),
      addressToward: (_) async => InternetAddress.loopbackIPv4,
    );
    await relay.allow(renderer);
    await relay.recheck();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(relay.allowed, isTrue);
  });

  test('turning it off closes the listener', () async {
    final relay = build();
    await relay.allow(renderer);
    await relay.revoke();
    expect(relay.allowed, isFalse);
    expect(relay.network, isNull);
    expect(proxy.relaying, isFalse);
  });

  test('a player this phone has no address toward cannot be served', () async {
    final relay = Relay(proxy,
        subnets: () async => here, addressToward: (_) async => null);
    expect(await relay.allow(renderer), isFalse);
    expect(relay.allowed, isFalse);
  });
}
