// Plays a video from a real UPnP server and checks that the subtitle tracks
// inside it can be listed, named, chosen, and still chosen after a seek.
//
// That last part is the point of the exercise: image-based subtitles (VobSub,
// from a DVD rip) stop rendering once you seek, which is why the library was
// remuxed to text. Run it against both copies to see the difference.
//
//   flutter test integration_test/video_test.dart -d <device> \
//     --dart-define=SERVER="NAS Video" --dart-define=TITLE="Hashoter Azulai T5"
//
// TITLE matches the first video whose title contains it, so the remuxed copy
// and the original share a title: FOLDER picks which one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:minstrel/app_services.dart';
import 'package:minstrel/main.dart';
import 'package:minstrel_core/minstrel_core.dart';

const serverName = String.fromEnvironment('SERVER', defaultValue: 'NAS Video');
const title = String.fromEnvironment('TITLE', defaultValue: 'Hashoter Azulai T5');
const folder = String.fromEnvironment('FOLDER', defaultValue: 'with-subs');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // main() does this in the app; the test doesn't run main().
  MediaKit.ensureInitialized();

  testWidgets('subtitle tracks can be listed, named, picked and kept across a seek',
      (tester) async {
    await AppServices.init();
    final app = AppServices.instance;
    await tester.pumpWidget(const MinstrelApp());

    expect(
        await _pumpUntil(tester, () => app.registry.servers.any((s) => s.name.contains(serverName)),
            timeout: const Duration(seconds: 40)),
        isTrue,
        reason: 'server "$serverName" not found on this network');
    final server = app.registry.servers.firstWhere((s) => s.name.contains(serverName));

    final item = await _find(server, inFolder: folder);
    expect(item, isNotNull, reason: 'no video containing "$title" under "$folder"');
    final uri = item!.resources.first.uri;
    debugPrint('playing ${item.title} from $uri');

    final player = Player();
    addTearDown(() async => player.dispose());
    player.stream.error.listen((e) => debugPrint('PLAYER ERROR: $e'));
    player.stream.log.listen((l) => debugPrint('mpv ${l.level}/${l.prefix}: ${l.text}'));
    player.stream.duration.listen((d) => debugPrint('duration: $d'));
    // The iOS Simulator has no audio device, and mpv gives up on the file
    // when it can't open one. Nothing being tested here needs sound.
    if (player.platform is NativePlayer) {
      await (player.platform! as NativePlayer).setProperty('ao', 'null');
    }
    await player.open(Media(uri.toString()));

    // mpv reports the file's tracks once it has opened it. Its own "auto"
    // and "no" entries are always there, so waiting on the list being
    // non-empty would return before anything had been read.
    List<SubtitleTrack> real() =>
        player.state.tracks.subtitle.where((s) => s.id != 'auto' && s.id != 'no').toList();
    expect(
        await _pumpUntil(tester, () => real().isNotEmpty, timeout: const Duration(seconds: 60)),
        isTrue,
        reason: 'no subtitle tracks reported for ${item.title} after 60s');

    final subs = real();
    debugPrint('subtitles: ${[
      for (final s in subs) '${s.id}:${s.title ?? ''}/${s.language ?? ''}'
    ]}');
    debugPrint('audio: ${[for (final a in player.state.tracks.audio) '${a.id}:${a.language ?? ''}']}');

    // Named, not just numbered: the language has to survive the remux, or
    // the picker shows "Track 2" and the user has to guess.
    final named = [for (final s in subs) languageName(s.language ?? '')];
    expect(named, contains('Hebrew'), reason: 'no Hebrew track among $named');

    final hebrew = subs[named.indexOf('Hebrew')];
    await player.setSubtitleTrack(hebrew);
    await player.play();
    expect(
        await _pumpUntil(tester, () => player.state.position > const Duration(seconds: 1),
            timeout: const Duration(seconds: 40)),
        isTrue,
        reason: 'playback did not start');

    await player.seek(const Duration(minutes: 20));
    expect(
        await _pumpUntil(tester, () => player.state.position > const Duration(minutes: 19),
            timeout: const Duration(seconds: 40)),
        isTrue,
        reason: 'the seek did not take');
    expect(player.state.track.subtitle.id, hebrew.id,
        reason: 'the subtitle track was lost across the seek');
    debugPrint('after seek: ${player.state.position.inSeconds}s, subtitle still ${hebrew.language}');
    await player.pause();
  });
}

/// The first video whose title contains [title], under a container named
/// [inFolder] when one is given.
Future<DidlItem?> _find(MediaServer server, {required String inFolder}) async {
  final seen = <String>{};
  final stack = <(String, String)>[('0', '')];
  DidlItem? loose;
  while (stack.isNotEmpty) {
    final (id, path) = stack.removeAt(0);
    if (!seen.add(id)) continue;
    final page = await server.contentDirectory.browse(id, count: 500);
    for (final o in page.objects) {
      if (o is DidlContainer) stack.add((o.id, '$path/${o.title}'));
      if (o is DidlItem && o.isVideo && o.title.contains(title)) {
        if (inFolder.isEmpty || path.contains(inFolder)) return o;
        loose ??= o;
      }
    }
  }
  return loose;
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
