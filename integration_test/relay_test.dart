// Plays a track from a paired home on a renderer on this network, which only
// works if the phone passes the music on. Run against a real launchpad and a
// real renderer:
//   flutter test integration_test/relay_test.dart -d <device> \
//     --dart-define=PAIRING_LINK="$(minstrel-launchpad pair | grep -o 'minstrel://.*')" \
//     --dart-define=RENDERER=CXNv2
//
// At home the launchpad's servers are hidden in the UI by the same servers on
// the LAN, so this reaches them through registry.homeServers, which is what
// the app would show anywhere else. The renderer plays briefly and is stopped.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minstrel/app_services.dart';
import 'package:minstrel/main.dart';
import 'package:minstrel_core/minstrel_core.dart';

const link = String.fromEnvironment('PAIRING_LINK');
const rendererName = String.fromEnvironment('RENDERER');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a renderer on this network plays a home track through the phone', (tester) async {
    expect(rendererName, isNotEmpty, reason: 'pass --dart-define=RENDERER=<part of its name>');
    await AppServices.init();
    final app = AppServices.instance;
    await tester.pumpWidget(const MinstrelApp());

    // A home already paired on this device is used as it is. Homes are not
    // removed here: this may be someone's own phone, and re-pairing it is
    // not this test's business.
    if (app.homes.homes.isEmpty) {
      expect(link, isNotEmpty, reason: 'no home paired here; pass --dart-define=PAIRING_LINK=...');
      await tester.tap(find.byTooltip('Add home'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), link);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair'));
      expect(await _pumpUntil(tester, () => app.homes.homes.isNotEmpty), isTrue, reason: 'pairing failed');
    }
    final home = app.homes.homes.first;
    expect(await _pumpUntil(tester, () => app.homes.status(home).state == HomeState.connected), isTrue,
        reason: 'home not reachable: ${app.homes.status(home).state}');

    expect(await _pumpUntil(tester, () => app.registry.homeServers(home.id).isNotEmpty), isTrue,
        reason: 'no servers behind the launchpad');

    // Tracks whose URLs only this device can fetch.
    List<DidlItem> tracks = const [];
    for (final s in app.registry.homeServers(home.id)) {
      try {
        final found = (await s.contentDirectory
                .search('0', 'upnp:class derivedfrom "object.item.audioItem"', count: 2))
            .objects
            .whereType<DidlItem>()
            .toList();
        if (found.length > tracks.length) tracks = found;
      } on Object catch (e) {
        debugPrint('${s.name}: $e');
      }
    }
    expect(tracks, isNotEmpty, reason: 'no tracks through the launchpad');
    expect(HomeProxy.isHomeUrl(tracks.first.resources.first.uri), isTrue);

    // The renderer on this network.
    expect(
        await _pumpUntil(tester,
            () => app.registry.renderers.any((r) => r.name.contains(rendererName)),
            timeout: const Duration(seconds: 30)),
        isTrue,
        reason: 'renderer "$rendererName" not found');
    final renderer = app.registry.renderers.firstWhere((r) => r.name.contains(rendererName));
    await app.player.switchOutput(app.outputFor(renderer.udn)!);
    expect(app.player.output.isLocal, isFalse);

    // Without permission the tracks are left out, and said so in their own
    // words rather than blamed on the renderer.
    await app.player.playItems(tracks, 0);
    expect(app.player.entries, isEmpty);
    expect(app.player.needRelay, hasLength(tracks.length));
    expect(app.player.skipped, isEmpty, reason: 'not a format problem');
    expect(app.relay.allowed, isFalse);

    // Permission, as the prompt would give it.
    expect(await app.relay.allow(renderer.device.location), isTrue,
        reason: 'could not open a listener toward ${renderer.device.location}');
    expect(app.relay.allowed, isTrue);
    debugPrint('relaying on ${app.relay.network}');

    await app.player.playItems(tracks, 0);
    expect(app.player.needRelay, isEmpty);
    expect(app.player.entries, hasLength(tracks.length));
    final url = app.player.entries.first.resource.uri;
    expect(HomeProxy.isRelayUrl(url), isTrue);
    expect(url.host, isNot('127.0.0.1'), reason: 'the renderer has to be able to reach it');
    debugPrint('renderer fetches $url');

    // The metadata has to name the same URL, or players that trust it over
    // the URI they were handed reject the track.
    final sent = parseDidlLite(app.player.entries.first.didl).single as DidlItem;
    expect(sent.resources.single.uri, url);

    // Anyone on this network can fetch what is queued, and nothing else.
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final ok = await (await client.getUrl(url)).close();
    expect(ok.statusCode, anyOf(200, 206));
    await ok.detachSocket().then((s) => s.destroy());
    final wrong = Uri.parse(url.toString().replaceFirst(RegExp('/r/[^/]+/'), '/r/nope/'));
    final denied = await (await client.getUrl(wrong)).close();
    expect(denied.statusCode, 404);
    await denied.drain<void>();

    // And the renderer really plays it.
    final playing = await _pumpUntil(
        tester,
        () => app.player.playbackState.value.playing &&
            app.player.playbackState.value.updatePosition > const Duration(seconds: 2),
        timeout: const Duration(seconds: 45));
    expect(playing, isTrue, reason: 'the renderer did not start playing the relayed track');
    debugPrint('playing ${app.player.mediaItem.value?.title} on ${renderer.name} '
        'at ${app.player.playbackState.value.updatePosition.inSeconds}s');
    await app.player.stop();

    // Leaving the network takes the permission away.
    await app.relay.revoke();
    expect(app.relay.allowed, isFalse);
    expect(app.homes.proxy.relaying, isFalse);

    // Put the device back on its own speaker.
    await app.player.switchOutput(app.player.localOutput);
  });
}

Future<bool> _pumpUntil(WidgetTester tester, bool Function() done,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (done()) return true;
  }
  return false;
}
