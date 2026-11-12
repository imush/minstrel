// Plays a track held on this device to a real renderer, through the relay.
// This is the one path no test can reach without hardware: the renderer
// fetches the bytes itself, with ranges, from a file on the phone.
//
//   flutter test integration_test/cache_relay_test.dart -d <device> \
//     --dart-define=RENDERER=Yamaha
//
// Needs a media server on this network and no launchpad: the cache keys on
// the server and path, so a plain LAN server is cached like any other.
// Nothing is left behind -- the track is removed and the relay closed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minstrel/app_services.dart';
import 'package:minstrel/main.dart';
import 'package:minstrel_core/minstrel_core.dart';

const rendererName = String.fromEnvironment('RENDERER');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a renderer plays a track held on this device', (tester) async {
    expect(rendererName, isNotEmpty, reason: 'pass --dart-define=RENDERER=<part of its name>');
    await AppServices.init();
    final app = AppServices.instance;
    await tester.pumpWidget(const MinstrelApp());

    // A server, and a track from it.
    expect(await _until(tester, () => app.registry.servers.isNotEmpty,
            timeout: const Duration(seconds: 30)),
        isTrue,
        reason: 'no media server on this network');
    DidlItem? found;
    for (final s in app.registry.servers) {
      try {
        found = (await s.contentDirectory
                .search('0', 'upnp:class derivedfrom "object.item.audioItem"', count: 1))
            .objects
            .whereType<DidlItem>()
            .firstOrNull;
      } on Object catch (e) {
        debugPrint('${s.name}: $e');
      }
      if (found != null) break;
    }
    final item = found;
    expect(item, isNotNull, reason: 'no tracks on any server here');

    // Hold it on this device, as asking to keep it would.
    final asked = app.cacheFetcher.request([item!]);
    debugPrint('requested: $asked');
    expect(await _until(tester, () => app.cache.heldFor(item) != null,
            timeout: const Duration(minutes: 2)),
        isTrue,
        reason: 'the track was never fetched into the cache');
    final held = app.cache.heldFor(item)!;
    addTearDown(() => app.cache.remove(held.key));
    debugPrint('holding ${held.bytes} bytes of ${item.title} '
        '(${held.resource.formatLabel}) as ${held.file}');

    // The renderer on this network.
    expect(
        await _until(tester, () => app.registry.renderers.any((r) => r.name.contains(rendererName)),
            timeout: const Duration(seconds: 30)),
        isTrue,
        reason: 'renderer "$rendererName" not found');
    final renderer = app.registry.renderers.firstWhere((r) => r.name.contains(rendererName));

    // Serve the copy on this network, and hand the renderer its URL.
    expect(await app.relay.allow(renderer.device.location), isTrue,
        reason: 'could not open a listener toward ${renderer.device.location}');
    addTearDown(app.relay.revoke);
    final url = app.homes.proxy.relayForCopy(held.file)!;
    expect(HomeProxy.isRelayedCopy(url), isTrue);
    app.homes.proxy.allowRelay([url]);
    debugPrint('renderer fetches $url');

    final output = app.outputFor(renderer.udn)!;
    addTearDown(() async {
      await output.stop();
      await output.dispose();
    });
    final entry = QueueEntry(item, held.resource.withUri(url));
    // The metadata has to name the same URL, or players that trust it over
    // the URI they were handed reject the track.
    expect((parseDidlLite(entry.didl).single as DidlItem).resources.single.uri, url);

    await output.load([entry], 0);
    expect(
        await _until(tester, () => output.state.playing && output.state.position > const Duration(seconds: 2),
            timeout: const Duration(seconds: 45)),
        isTrue,
        reason: 'the renderer did not start playing the held copy');
    debugPrint('playing on ${renderer.name} at ${output.state.position.inSeconds}s');
    expect(app.homes.proxy.relayServed, greaterThan(0), reason: 'it never fetched');

    // Seeking is what makes a player ask for a range, and ranges are the
    // part of serving a file from here that hardware decides.
    await output.seek(const Duration(seconds: 40));
    expect(
        await _until(tester, () => output.state.position > const Duration(seconds: 42),
            timeout: const Duration(seconds: 30)),
        isTrue,
        reason: 'seeking into the held copy did not resume: a range problem');
    debugPrint('after seek, at ${output.state.position.inSeconds}s');
  });
}

Future<bool> _until(WidgetTester tester, bool Function() done,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (done()) return true;
  }
  return false;
}
