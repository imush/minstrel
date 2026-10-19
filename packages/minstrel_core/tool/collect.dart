// Prints what "add folder to queue" would collect from a server container.
//   dart run tool/collect.dart <container id>
import 'package:http/http.dart' as http;
import 'package:minstrel_core/minstrel_core.dart';

Future<void> main(List<String> args) async {
  final reg = DeviceRegistry(http.Client());
  await reg.start();
  await Future<void>.delayed(const Duration(seconds: 4));
  final server = reg.servers.first;
  final sw = Stopwatch()..start();
  final tracks = await server.contentDirectory.collectTracks(args.isEmpty ? '0' : args[0]);
  print('${tracks.length} tracks in ${sw.elapsedMilliseconds} ms');
  for (final t in tracks.take(8)) {
    print('  ${t.album} / ${t.title}');
  }
  await reg.dispose();
}
