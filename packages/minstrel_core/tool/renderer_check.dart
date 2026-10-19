// Live check of queue handling on a real renderer. Plays audio out loud.
//   dart run tool/renderer_check.dart "<renderer name>" [<server container id>]
// Loads up to four tracks from the first media server's container, starts at
// the second, steps forward and back, then jumps near the end of a track and
// checks the renderer moves on by itself.
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:minstrel_core/minstrel_core.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: renderer_check.dart "<renderer name>" [container id]');
    exit(64);
  }
  final reg = DeviceRegistry(http.Client());
  await reg.start();
  await Future<void>.delayed(const Duration(seconds: 4));
  final renderer = reg.renderers.where((r) => r.name == args[0]).firstOrNull;
  final server = reg.servers.firstOrNull;
  if (renderer == null || server == null) {
    stderr.writeln('renderer or server not found: ${reg.renderers.map((r) => r.name)}');
    exit(1);
  }
  print('renderer: ${renderer.name}, strategy ${renderer.strategy.name}');

  // Find a container with at least four tracks.
  var id = args.length > 1 ? args[1] : '0';
  List<DidlItem> items = const [];
  for (var depth = 0; depth < 8 && items.length < 4; depth++) {
    final page = await server.contentDirectory.browse(id, count: 20);
    items = page.objects.whereType<DidlItem>().where((i) => i.isAudio).toList();
    if (items.length < 4) id = page.objects.whereType<DidlContainer>().first.id;
  }
  final sinks = await renderer.sinks();
  final entries = [
    for (final i in items.take(4))
      if (ResourceSelector.select(i, sinks) case final r?) QueueEntry(i, r),
  ];
  print('tracks: ${entries.map((e) => e.item.title).join(' | ')}');

  final q = await renderer.createQueue();
  Future<String> now([int wait = 3]) async {
    await Future<void>.delayed(Duration(seconds: wait));
    final s = q.current;
    return 'index ${s.index} ${s.state.name} ${s.position.inSeconds}s';
  }

  var ok = true;
  void check(String what, bool pass, String detail) {
    ok &= pass;
    print('${pass ? 'PASS' : 'FAIL'} $what: $detail');
  }

  await q.playQueue(entries, startIndex: 1);
  var s = await now(4);
  check('starts at track 2', q.current.index == 1 && q.current.state == TransportState.playing, s);
  await q.skipTo(2);
  s = await now();
  check('skip forward', q.current.index == 2, s);
  await q.skipTo(1);
  s = await now();
  check('skip back within loaded list', q.current.index == 1, s);
  await q.skipTo(0);
  s = await now(4);
  check('skip back before loaded list (reload)', q.current.index == 0, s);

  final d = q.current.duration ?? entries[0].item.duration;
  if (d != null) {
    await q.seek(d - const Duration(seconds: 4));
    s = await now(9);
    check('renderer advances by itself', q.current.index == 1, s);
  }
  await q.stop();
  await q.dispose();
  await reg.dispose();
  exit(ok ? 0 : 1);
}
