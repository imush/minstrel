// Writes a saved-queue file, as the app would, from the first album found
// on the LAN's media server. For testing restore:
//   dart run tool/make_snapshot.dart <out.json> [index] [seconds]
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:minstrel_core/minstrel_core.dart';

Future<void> main(List<String> args) async {
  final reg = DeviceRegistry(http.Client());
  await reg.start();
  await Future<void>.delayed(const Duration(seconds: 4));
  final server = reg.servers.firstWhere((s) => s.device.modelName == 'MinimServer',
      orElse: () => reg.servers.first);
  var id = '0';
  var items = <DidlItem>[];
  for (var depth = 0; depth < 8 && items.length < 3; depth++) {
    final page = await server.contentDirectory.browse(id, count: 50);
    items = page.objects.whereType<DidlItem>().toList();
    if (items.length < 3) id = page.objects.whereType<DidlContainer>().first.id;
  }
  final entries = [
    for (final i in items)
      if (ResourceSelector.select(i, LocalSinks.apple) case final r?) QueueEntry(i, r),
  ];
  final snap = QueueSnapshot(
    outputId: 'local',
    entries: entries,
    index: args.length > 1 ? int.parse(args[1]) : 2,
    position: Duration(seconds: args.length > 2 ? int.parse(args[2]) : 45),
  );
  File(args[0]).writeAsStringSync(snap.encode());
  print('${entries.length} tracks, #${snap.index + 1} "${entries[snap.index].item.title}" at ${snap.position.inSeconds}s');
  await reg.dispose();
  exit(0);
}
