// Pairs with a running minstrel-launchpad through the UI, then browses and
// plays (muted, on this device) through it:
//   flutter test integration_test/home_test.dart -d <device> \
//     --dart-define=PAIRING_LINK="$(minstrel-launchpad pair | grep -o 'minstrel://.*')"
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minstrel/app_services.dart';
import 'package:minstrel/main.dart';
import 'package:minstrel_core/minstrel_core.dart';

const link = String.fromEnvironment('PAIRING_LINK');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pair with a launchpad and play through it', (tester) async {
    expect(link, isNotEmpty, reason: 'pass --dart-define=PAIRING_LINK=...');
    await AppServices.init();
    final app = AppServices.instance;
    await app.player.localOutput.setVolume(0);
    for (final h in app.homes.homes) {
      await app.homes.remove(h); // start clean
    }
    await tester.pumpWidget(const MinstrelApp());

    // Pair through the UI, with the link (no camera in the simulator).
    await tester.tap(find.byTooltip('Add home'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), link);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pair'));
    final paired = await _pumpUntil(tester, () => find.textContaining('Paired with').evaluate().isNotEmpty);
    expect(paired, isTrue, reason: find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join(' | '));
    final home = app.homes.homes.single;
    debugPrint('paired: ${home.name}, status ${app.homes.status(home).state} via ${app.homes.status(home).address}');
    expect(app.homes.status(home).state, HomeState.connected);

    final listed = await _pumpUntil(tester, () => app.registry.homeServers(home.id).isNotEmpty);
    expect(listed, isTrue, reason: 'no servers behind the launchpad');
    final servers = app.registry.homeServers(home.id);
    debugPrint('through home: ${servers.map((s) => '${s.name} @ ${s.device.location}')}');
    await tester.pumpAndSettle();
    expect(find.text('Homes'), findsOneWidget);

    // Find tracks on the richest server, through the launchpad.
    MediaServer? server;
    List<DidlItem> tracks = const [];
    for (final s in servers) {
      try {
        final found = (await s.contentDirectory
                .search('0', 'upnp:class derivedfrom "object.item.audioItem"', count: 3))
            .objects
            .whereType<DidlItem>()
            .toList();
        if (found.length > tracks.length) (server, tracks) = (s, found);
      } on Object catch (e) {
        debugPrint('${s.name}: $e');
      }
    }
    expect(tracks, isNotEmpty, reason: 'no tracks found through the launchpad');
    final res = tracks.first.resources.first.uri;
    debugPrint('${server!.name}: ${tracks.first.title} at $res');
    expect(HomeProxy.isHomeUrl(res), isTrue, reason: 'media URL goes through the local proxy');

    await app.player.playItems(tracks, 0);
    final playing = await _pumpUntil(tester, () =>
        app.player.playbackState.value.playing &&
        app.player.playbackState.value.updatePosition > const Duration(seconds: 2),
        timeout: const Duration(seconds: 30));
    expect(playing, isTrue, reason: 'playback through the launchpad did not start');
    await app.player.seek(const Duration(seconds: 60));
    final seeked = await _pumpUntil(tester, () =>
        app.player.playbackState.value.updatePosition >= const Duration(seconds: 61));
    expect(seeked, isTrue, reason: 'seek (a range request) through the launchpad');
    debugPrint('played ${app.player.mediaItem.value?.title} to '
        '${app.player.playbackState.value.updatePosition.inSeconds}s');
    await app.player.stop();
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
