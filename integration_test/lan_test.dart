// Runs the real app against the media server on the developer's LAN:
//   flutter test integration_test -d macos
// Local playback is muted; nothing is sent to network renderers.
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minstrel/app_services.dart';
import 'package:minstrel/main.dart';
import 'package:minstrel_core/minstrel_core.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('discover, browse to a track, play it gaplessly into the next', (tester) async {
    await AppServices.init();
    final app = AppServices.instance;
    await app.player.localOutput.setVolume(0);
    await tester.pumpWidget(const MinstrelApp());

    // Discovery
    final serverFound = await _pumpUntil(tester, () => app.registry.servers.isNotEmpty);
    expect(serverFound, isTrue, reason: 'no media server discovered on the LAN');
    // Other servers may come and go on the LAN (phones sharing media, with
    // remote browsing off); use the one with the most top-level content.
    await Future<void>.delayed(const Duration(seconds: 2));
    final sizes = {
      for (final s in app.registry.servers) s: (await s.contentDirectory.browse('0')).objects.length,
    };
    final server = sizes.keys.reduce((a, b) => sizes[a]! >= sizes[b]! ? a : b);
    expect(find.text(server.name), findsOneWidget);
    debugPrint('server: ${server.name}; renderers: ${app.registry.renderers.map((r) => r.name)}');

    // Browse by tapping through the UI until a page with tracks appears.
    await tester.tap(find.text(server.name));
    await tester.pumpAndSettle();
    for (var depth = 0; depth < 8; depth++) {
      await _pumpUntil(tester, () => find.byType(ListTile).evaluate().isNotEmpty);
      final title = tester.widgetList<AppBar>(find.byType(AppBar)).last.title;
      debugPrint('depth $depth: ${(title as Text?)?.data} tiles=${find.byType(ListTile).evaluate().length}');
      if (find.byTooltip('Play all').evaluate().isNotEmpty) break;
      // Prefer the album list; otherwise the first container.
      final albums = find.descendant(
          of: find.byType(ListTile), matching: find.textContaining('albums'));
      await tester.tap(albums.evaluate().isNotEmpty ? albums.first : find.byType(ListTile).first);
      await tester.pumpAndSettle();
    }
    expect(find.byTooltip('Play all'), findsOneWidget, reason: 'never reached a page of tracks');

    // Play the first track, then jump near its end and watch the handover.
    await tester.tap(find.byTooltip('Play all'));
    final playing = await _pumpUntil(tester, () => app.player.playbackState.value.playing &&
        app.player.playbackState.value.updatePosition > const Duration(seconds: 1));
    expect(playing, isTrue, reason: 'local playback did not start');
    final first = app.player.mediaItem.value!;
    debugPrint('playing: ${first.title} [${first.extras?['format']}] of ${app.player.entries.length}');
    expect(find.byType(LinearProgressIndicator), findsWidgets, reason: 'mini player shown');

    if (app.player.entries.length > 1 && first.duration != null) {
      await app.player.seek(first.duration! - const Duration(seconds: 3));
      final advanced = await _pumpUntil(
          tester, () => app.player.playbackState.value.queueIndex == 1,
          timeout: const Duration(seconds: 20));
      expect(advanced, isTrue, reason: 'did not advance to the second track');
      expect(app.player.playbackState.value.processingState, isNot(AudioProcessingState.error));
      debugPrint('advanced to: ${app.player.mediaItem.value?.title}');
    }

    // Queue editing on the live player.
    final player = app.player;
    final items = [for (final e in player.entries) e.item];
    final current = player.playbackState.value.queueIndex!;
    final before = player.entries.length;
    await player.playNext([items.last]);
    expect(player.entries[current + 1].item.id, items.last.id, reason: 'play next lands after current');
    await player.addToQueue([items.first]);
    expect(player.entries.last.item.id, items.first.id, reason: 'add to queue appends');
    expect(player.entries, hasLength(before + 2));
    await player.removeQueueItemAt(current + 1);
    expect(player.entries, hasLength(before + 1));
    await player.moveQueueItem(player.entries.length - 1, current + 1);
    expect(player.entries[current + 1].item.id, items.first.id, reason: 'moved up next');
    expect(player.queue.value, hasLength(player.entries.length));
    await tester.pump(const Duration(seconds: 1));
    expect(player.playbackState.value.queueIndex, current, reason: 'edits kept the current track');
    expect(player.playbackState.value.playing, isTrue);
    debugPrint('queue edits ok: ${player.entries.length} tracks, still on #${current + 1}');

    // Folder actions in the UI: open the "more" menu on the page and add all.
    await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byTooltip('More')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue'));
    await _pumpUntil(tester, () => find.textContaining('to the queue').evaluate().isNotEmpty);
    expect(find.textContaining('Added ${items.length} tracks to the queue'), findsOneWidget);
    debugPrint('menu: ${(tester.widget<Text>(find.textContaining('to the queue'))).data}');


    // Restart recovery: save, clear, restore, resume where we were.
    await player.seek(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 1));
    final snap = QueueSnapshot.decode(player.snapshot().encode())!;
    final at = snap.index;
    await player.clearQueue();
    expect(player.entries, isEmpty);
    player.restore(snap);
    expect(player.hasPendingQueue, isTrue);
    expect(player.mediaItem.value?.title, snap.entries[at].item.title, reason: 'shown before playing');
    expect(player.playbackState.value.playing, isFalse);
    await player.play();
    final resumed = await _pumpUntil(tester, () =>
        player.playbackState.value.playing &&
        player.playbackState.value.queueIndex == at &&
        player.playbackState.value.updatePosition >= const Duration(seconds: 29));
    expect(resumed, isTrue, reason: 'resumed at the saved track and position');
    debugPrint('restored: #${at + 1} of ${snap.entries.length} at '
        '${player.playbackState.value.updatePosition.inSeconds}s');

    await app.player.stop();
  });
}

Future<bool> _pumpUntil(WidgetTester tester, bool Function() done,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (done()) return true;
  }
  return false;
}

