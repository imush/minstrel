// Walks through the main screens for App Store and Play screenshots, with a
// media server and players on the LAN and a paired launchpad. At each
// screen it asks the host to capture the simulator, through files in the
// app's Documents folder (see tool/screenshots.sh, which runs this):
//   flutter test integration_test/screenshots_test.dart -d <simulator> \
//     --dart-define=PAIRING_LINK="..." --dart-define=SERVER="MinimServer[minim]" \
//     --dart-define=ALBUMS="624 albums" --dart-define=ALBUM="..."
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minstrel/app_services.dart';
import 'package:minstrel/main.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:path_provider/path_provider.dart';

const link = String.fromEnvironment('PAIRING_LINK');
const serverName = String.fromEnvironment('SERVER');
const albumsFolder = String.fromEnvironment('ALBUMS');
const albumName = String.fromEnvironment('ALBUM');
// The album to scroll to the top of the list, for a better-looking first screen.
const topAlbum = String.fromEnvironment('TOP_ALBUM');
const homeName = String.fromEnvironment('HOME_NAME', defaultValue: 'Home');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screenshots', (tester) async {
    await AppServices.init();
    final app = AppServices.instance;
    await app.player.localOutput.setVolume(0);
    for (final h in app.homes.homes) {
      await app.homes.remove(h);
    }
    if (link.isNotEmpty) {
      final home = await app.homes.pair(PairingInvitation.parse(link)!, deviceName: 'Screenshots');
      // Named on this device, so the launchpad's own name doesn't show.
      await app.homes.rename(home, homeName);
    }
    await tester.pumpWidget(const MinstrelApp());

    // 1. Servers: the home, the media server and the players.
    await _pumpUntil(tester, () =>
        find.text(serverName).evaluate().isNotEmpty &&
        app.registry.renderers.isNotEmpty &&
        (link.isEmpty || find.textContaining('Connected').evaluate().isNotEmpty));
    await _settle(tester);
    await shot(tester, '1-servers');

    // 2. Albums, with artwork.
    await tester.tap(find.text(serverName).first);
    await _pumpUntil(tester, () => find.text(albumsFolder).evaluate().isNotEmpty);
    await tester.tap(find.text(albumsFolder));
    await _pumpUntil(tester, () => find.byType(ListTile).evaluate().length > 3);
    if (topAlbum.isNotEmpty) {
      await _pumpUntil(tester, () => find.text(topAlbum).evaluate().isNotEmpty);
      await Scrollable.ensureVisible(tester.element(find.text(topAlbum)));
    }
    await _settle(tester, seconds: 4);
    await shot(tester, '2-albums');

    // 3. An album's tracks.
    await tester.scrollUntilVisible(find.text(albumName), 200, scrollable: find.byType(Scrollable).first);
    await _settle(tester);
    await tester.tap(find.text(albumName));
    await _pumpUntil(tester, () => find.byTooltip('Play all').evaluate().isNotEmpty);
    await _settle(tester, seconds: 3);
    await shot(tester, '3-album');

    // 4. Now playing (muted, on this device).
    await tester.tap(find.byTooltip('Play all'));
    await _pumpUntil(tester, () => app.player.playbackState.value.playing, timeout: const Duration(seconds: 30));
    await _settle(tester, seconds: 4);
    await _openNowPlaying(tester);
    await _settle(tester, seconds: 3);
    await shot(tester, '4-now-playing');

    // 5. Where to play: the players at home. Nothing is chosen.
    // On Now Playing, the output is the button under the controls.
    await tester.tap(find.text('This device').last);
    await _settle(tester, seconds: 2);
    await shot(tester, '5-players');
    await app.player.pause();

    // 6. Settings: quality away from home.
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.popUntil((r) => r.isFirst);
    await _settle(tester);
    await tester.tap(find.byTooltip('Settings'));
    await _settle(tester, seconds: 2);
    await shot(tester, '6-settings');

    await app.player.stop();
    for (final h in app.homes.homes) {
      await app.homes.remove(h);
    }
  });
}

/// Opens Now Playing from the mini player at the bottom.
Future<void> _openNowPlaying(WidgetTester tester) async {
  final mini = find.byKey(const ValueKey('mini-player'));
  if (mini.evaluate().isNotEmpty) {
    await tester.tap(mini);
  }
  await _settle(tester, seconds: 2);
}

/// Asks the host for a capture of the whole simulator screen and waits for it.
Future<void> shot(WidgetTester tester, String name) async {
  final dir = await getApplicationDocumentsDirectory();
  final request = File('${dir.path}/shot-request');
  final done = File('${dir.path}/shot-done');
  if (done.existsSync()) done.deleteSync();
  request.writeAsStringSync(name);
  debugPrint('screenshot: $name');
  final ok = await _pumpUntil(tester, done.existsSync, timeout: const Duration(seconds: 30));
  expect(ok, isTrue, reason: 'no capture of $name: is tool/screenshots.sh watching?');
  done.deleteSync();
}

/// Lets images load and animations finish, in real time.
Future<void> _settle(WidgetTester tester, {int seconds = 1}) async {
  for (var i = 0; i < seconds * 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
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
