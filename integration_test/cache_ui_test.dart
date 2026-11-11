// Boots the real app on a device and walks into the offline screens, which
// is the only way to find out that starting the cache, measuring the
// device and building those pages all work where they have to.
//
//   flutter test integration_test/cache_ui_test.dart -d <device>
//
// Needs no server and no paired home: an empty cache is the state every
// install starts in, and the one most likely to be got wrong.
//
// Starting the services takes longer than the harness will wait on an
// emulated x86_64 Android image, which spends seconds merely loading
// libflutter; it has been run on the iOS simulator and should be run on a
// real Android device rather than an emulator. What the platform has to
// answer for -- free space, and saving to Downloads -- is covered without
// starting the app at all by cache_platform_test.dart, which does pass on
// an emulator.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minstrel/app_services.dart';
import 'package:minstrel/cache/cache_store.dart';
import 'package:minstrel/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps for a while without demanding the app go still.
  ///
  /// Not pumpAndSettle: discovery keeps a spinner turning while it looks
  /// for servers, so on a machine with none to find there is no moment
  /// when nothing is animating.
  Future<void> settle(WidgetTester tester,
      {Duration about = const Duration(seconds: 2)}) async {
    final end = DateTime.now().add(about);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the cache starts up and its screens open', (tester) async {
    debugPrint('CHECKPOINT starting services');
    await AppServices.init();
    debugPrint('CHECKPOINT services up');
    final app = AppServices.instance;
    await tester.pumpWidget(const MinstrelApp());
    await settle(tester);
    debugPrint('CHECKPOINT app drawn');

    // Set up from the device's own free space, not a guess.
    expect(app.cache.enabled, isTrue, reason: 'on by default');
    expect(app.cache.budget, greaterThan(0), reason: 'a tenth of what is free');
    expect(app.cache.dir.path, endsWith('music-cache'));
    debugPrint('budget ${app.cache.budget ~/ gigabyte} GB, '
        'holding ${app.cache.bytes} bytes');

    // The listing, reached as a source beside the servers.
    await tester.tap(find.text('On this device'));
    await settle(tester);
    expect(find.text('Nothing here yet. Music you play at home is kept automatically, '
        'and you can choose an album to keep from its menu.'), findsOne);
    // The Now Playing bar belongs here like anywhere else; with nothing
    // playing it simply takes no room.
    expect(find.byType(Scaffold), findsWidgets);
    await tester.pageBack();
    await settle(tester);

    // Settings: the switch, the size slider and what the device has left.
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Keep music on this device'), 200,
        duration: const Duration(milliseconds: 50));
    await settle(tester);
    expect(find.byType(Slider), findsOne);
    final summary = tester.widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .firstWhere((s) => s.startsWith('Holding '), orElse: () => '');
    expect(summary, isNotEmpty, reason: 'the size summary should be shown');
    debugPrint('settings says: $summary');
    expect(summary, contains('free on this device'),
        reason: 'the platform did not report free space');

    // And it can be turned off and on without asking, while empty.
    await tester.tap(find.text('Keep music on this device'));
    await settle(tester);
    expect(app.cache.enabled, isFalse);
    await tester.tap(find.text('Keep music on this device'));
    await settle(tester);
    expect(app.cache.enabled, isTrue);
  });
}
