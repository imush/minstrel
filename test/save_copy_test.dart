// Naming a file the save sheet will offer, and picking which copy to fetch.
// The name comes from the server, so it is also where a hostile one would
// try to get out of the directory it is written to.
import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/download/save_copy.dart';
import 'package:minstrel_core/minstrel_core.dart';

DidlItem video(String title, List<DidlResource> resources) => parseDidlLite(
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="1" parentID="0" restricted="1"><dc:title>$title</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      '${resources.map((r) => '<res protocolInfo="http-get:*:${r.mimeType}:*"'
          '${r.size == null ? '' : ' size="${r.size}"'}>${r.uri}</res>').join()}'
      '</item></DIDL-Lite>',
    ).whereType<DidlItem>().single;

DidlResource res(String uri, {String mime = 'video/mp4', int? size}) => DidlResource(
      uri: Uri.parse(uri),
      protocolInfo: ProtocolInfo.parse('http-get:*:$mime:*'),
      size: size,
    );

void main() {
  group('what to fetch', () {
    test('the largest copy: a thumbnail is not what "save" means', () {
      final item = video('Film', [
        res('http://s/thumb.jpg', mime: 'image/jpeg', size: 40000),
        res('http://s/film.mp4', size: 900000000),
      ]);
      expect(biggestResource(item)!.uri.path, '/film.mp4');
    });

    test('nothing fetchable over http is nothing to save', () {
      final item = video('Film', [res('rtsp://s/live')]);
      expect(biggestResource(item), isNull);
    });
  });

  group('what to call it', () {
    test("the server's own file name, which is what it is called at home", () {
      final r = res('http://s/movies/The%20Film%20(1954).mkv', mime: 'video/x-matroska');
      expect(saveFileName(video('The Film', [r]), r), 'The Film (1954).mkv');
    });

    test('the title plus an extension, when the URL has no name', () {
      final r = res('http://s/content/media/id/4821');
      expect(saveFileName(video('Holiday', [r]), r), 'Holiday.mp4');
    });

    test('an unknown format leaves the extension off rather than guessing', () {
      final r = res('http://s/get?id=9', mime: 'application/x-weird');
      expect(saveFileName(video('Thing', [r]), r), 'Thing');
    });

    test('a name cannot climb out of the directory it is written to', () {
      final r = res('http://s/%2e%2e%2f%2e%2e%2fetc%2fpasswd');
      final name = saveFileName(video('x', [r]), r);
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(r'\')));
    });

    test('a title with separators in it is made safe too', () {
      final r = res('http://s/content/4821');
      expect(saveFileName(video('AC/DC: Live', [r]), r), 'AC_DC_ Live.mp4');
    });

    test('a title that is nothing usable still gives a file name', () {
      final r = res('http://s/content/4821', mime: 'application/x-weird');
      expect(saveFileName(video('..', [r]), r), 'download');
    });
  });
}
