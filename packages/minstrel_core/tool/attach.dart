// Shows the queue the app would recover from a renderer, without changing
// anything on it.   dart run tool/attach.dart "<renderer name>"
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:minstrel_core/minstrel_core.dart';

Future<void> main(List<String> args) async {
  final reg = DeviceRegistry(http.Client());
  await reg.start();
  await Future<void>.delayed(const Duration(seconds: 4));
  final r = reg.renderers.where((r) => args.isEmpty || r.name == args[0]).firstOrNull;
  if (r == null) {
    stderr.writeln('not found: ${reg.renderers.map((r) => r.name)}');
    exit(1);
  }
  final q = await r.createQueue();
  final attached = await q.attach(const []);
  print('${r.name} (${r.strategy.name}): attached=$attached, ${q.queue.length} tracks, '
      'current #${q.index + 1}, ${q.current.state.name} at ${q.current.position.inSeconds}s');
  for (final (i, e) in q.queue.indexed) {
    final mark = i == q.index ? '>' : ' ';
    print('$mark ${i + 1}. ${e.item.title} — ${e.item.performer ?? '?'} '
        '[${e.resource.duration?.inSeconds ?? '?'}s]');
  }
  await q.dispose();
  await reg.dispose();
  exit(0);
}
