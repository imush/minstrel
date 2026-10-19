// Live check against the LAN: discover, browse, read renderer capabilities.
// Plays nothing. Run with: dart run tool/smoke.dart
import 'package:http/http.dart' as http;
import 'package:minstrel_core/minstrel_core.dart';

Future<void> main() async {
  final reg = DeviceRegistry(http.Client());
  await reg.start();
  await Future<void>.delayed(const Duration(seconds: 4));
  for (final s in reg.servers) {
    print('server: ${s.name} ${s.device.location}');
    final root = await s.contentDirectory.browse('0', count: 20);
    print('  root: ${root.objects.map((o) => o.title).join(' | ')}');
    var id = '0';
    for (var depth = 0; depth < 6; depth++) {
      final page = await s.contentDirectory.browse(id, count: 5);
      final item = page.objects.whereType<DidlItem>().firstOrNull;
      if (item != null) {
        final r = item.resources.first;
        print('  item: ${item.title} / ${item.composer ?? item.performer} / ${r.formatLabel}');
        for (final rd in reg.renderers) {
          final sel = ResourceSelector.select(item, await rd.sinks());
          print('  on ${rd.name}: ${sel?.formatLabel ?? 'not playable'}');
        }
        break;
      }
      id = page.objects.whereType<DidlContainer>().last.id;
    }
  }
  for (final r in reg.renderers) {
    print('renderer: ${r.name} sinks=${(await r.sinks()).length} setNext=${await r.supportsSetNext()} '
        'strategy=${r.strategy.name} volume=${await r.volume()}');
  }
  await reg.dispose();
}
