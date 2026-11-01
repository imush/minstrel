import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

/// A ContentDirectory that answers Search from a fixed library, matching
/// criteria the way MinimServer does for the one shape LibrarySearch sends.
class FakeLibrary {
  final String caps;
  final bool refuseDerivedFrom;
  final criteria = <String>[];

  FakeLibrary({this.caps = _minimCaps, this.refuseDerivedFrom = false});

  static const _minimCaps = 'upnp:class,dc:title,dc:creator,upnp:artist,upnp:album,upnp:genre,dc:date,res,'
      '@refID,upnp:artist[@role="AlbumArtist"],upnp:artist[@role="Composer"]';

  static const _objects = [
    '<container id="ar1" parentID="0"><dc:title>Shura Cherkassky</dc:title>'
        '<upnp:class>object.container.person.musicArtist</upnp:class></container>',
    '<container id="al1" parentID="0"><dc:title>Cherkassky - Piano Recital</dc:title>'
        '<upnp:artist>Shura Cherkassky</upnp:artist><upnp:artist role="Composer">Alban Berg</upnp:artist>'
        '<upnp:class>object.container.album.musicAlbum</upnp:class></container>',
    '<item id="t1" parentID="al1"><dc:title>Piano Sonata, Op. 1</dc:title><upnp:artist>Shura Cherkassky</upnp:artist>'
        '<upnp:artist role="Composer">Alban Berg</upnp:artist><upnp:album>Cherkassky - Piano Recital</upnp:album>'
        '<res protocolInfo="http-get:*:audio/flac:*">http://s/1.flac</res>'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class></item>',
    '<item id="t2" parentID="al1"><dc:title>Dvořák: Humoresque</dc:title><upnp:artist>Shura Cherkassky</upnp:artist>'
        '<upnp:album>Cherkassky - Piano Recital</upnp:album>'
        '<res protocolInfo="http-get:*:audio/flac:*">http://s/2.flac</res>'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class></item>',
  ];

  late final client = MockClient((req) async {
    final action = req.headers['SOAPACTION']!.split('#').last.replaceAll('"', '');
    final body = XmlDocument.parse(req.body);
    String arg(String n) => body.descendantElements.firstWhere((e) => e.name.local == n).innerText;
    String out;
    if (action == 'GetSearchCapabilities') {
      out = '<SearchCaps>${const HtmlEscape().convert(caps)}</SearchCaps>';
    } else {
      final c = arg('SearchCriteria');
      criteria.add(c);
      if (refuseDerivedFrom && c.contains('derivedfrom')) {
        return http.Response(
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>'
            '<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>708</errorCode>'
            '<errorDescription>Unsupported search criteria</errorDescription></UPnPError></detail>'
            '</s:Fault></s:Body></s:Envelope>',
            500);
      }
      final cls = RegExp(r'derivedfrom "([^"]+)"').firstMatch(c)?.group(1);
      final word = RegExp(r'contains "([^"]+)"').firstMatch(c)!.group(1)!.toLowerCase();
      final hits = _objects.where((o) {
        final e = XmlDocument.parse(o).rootElement;
        final klass = e.childElements.firstWhere((x) => x.name.local == 'class').innerText;
        return (cls == null || klass.startsWith(cls)) && e.innerText.toLowerCase().contains(word);
      });
      final didl = wrapDidlLite(hits.join());
      out = '<Result>${const HtmlEscape().convert(didl)}</Result>'
          '<NumberReturned>${hits.length}</NumberReturned><TotalMatches>${hits.length}</TotalMatches>';
    }
    return http.Response.bytes(
        utf8.encode('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
            '<u:${action}Response xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">$out'
            '</u:${action}Response></s:Body></s:Envelope>'),
        200,
        headers: {'content-type': 'text/xml; charset="utf-8"'});
  });

  LibrarySearch get search => LibrarySearch(ContentDirectory(
      SoapClient(client),
      UpnpService(
        serviceType: 'urn:schemas-upnp-org:service:ContentDirectory:1',
        serviceId: 'cd',
        controlUrl: Uri.parse('http://s/cd'),
        eventSubUrl: Uri.parse('http://s/ev'),
        scpdUrl: Uri.parse('http://s/scpd'),
      )));
}

void main() {
  test('search capabilities split outside role filters', () {
    expect(parseSearchCapabilities('dc:title, upnp:artist[@role="Composer"],upnp:album'),
        {'dc:title', 'upnp:artist[@role="Composer"]', 'upnp:album'});
    expect(parseSearchCapabilities(''), isEmpty);
  });

  test('criteria take one shape: a class and alternatives', () {
    expect(searchCriteria('berg', ['dc:title', 'upnp:artist'], upnpClass: 'object.item.audioItem'),
        'upnp:class derivedfrom "object.item.audioItem" and (dc:title contains "berg" or upnp:artist contains "berg")');
    expect(searchCriteria('say "hi"', ['dc:title']), r'dc:title contains "say \"hi\""');
  });

  test('finds artists, albums and tracks; the rarest word goes to the server', () async {
    final lib = FakeLibrary();
    final r = await lib.search.search('berg cherkassky');
    expect(r.artists, isEmpty); // the artist's name has no "berg"
    expect(r.albums.map((a) => a.id), ['al1']);
    expect(r.tracks.map((t) => t.id), ['t1']);
    // "berg" matches fewer objects than "cherkassky".
    expect(lib.criteria.where((c) => c.contains('derivedfrom')), everyElement(contains('"berg"')));
    expect(lib.criteria.last, contains('upnp:artist[@role="Composer"] contains'));
  });

  test('words after the first match without accents', () async {
    final r = await FakeLibrary().search.search('cherkassky dvorak');
    expect(r.tracks.map((t) => t.title), ['Dvořák: Humoresque']);
  });

  test('a word typed without accents finds the accented spelling', () async {
    expect(searchPieces('dvorak'), ['dv', 'ak']);
    expect(searchPieces('haidn'), ['ha', 'dn']);
    expect(searchPieces('cherkasky'), ['che', 'sky']);
    expect(searchPieces('berg'), isEmpty);
    expect(searchPieces('dvořák'), ['dv', 'ák']);
    final r = await FakeLibrary().search.search('dvorak');
    expect(r.tracks.map((t) => t.title), ['Dvořák: Humoresque']);
  });

  test('near misses match, after exact matches', () {
    expect(editDistance('griboedov', 'griboyedov'), 1);
    expect(editDistance('tchaikovski', 'tchaikovsky'), 1);
    expect(editDistance('rachmaninoff', 'rachmaninov'), 2);
    expect(editDistance('abcd', 'abdc'), 1); // a swap counts once
    expect(matchScore(['griboedov'], 'woe from wit · aleksandr griboyedov'), 1);
    expect(matchScore(['wit', 'griboedov'], 'woe from wit · aleksandr griboyedov'), 1);
    expect(matchScore(['griboyedov'], 'aleksandr griboyedov'), 0);
    expect(matchScore(['berk'], 'alban berg'), isNull); // short words must match exactly
    expect(matchScore(['griboedov'], 'mussorgsky'), isNull);
  });

  test('a misspelt name finds the right one through its pieces', () async {
    final lib = FakeLibrary();
    final r = await lib.search.search('cherkasky');
    expect(r.artists.map((a) => a.title), ['Shura Cherkassky']);
    expect(r.tracks.map((t) => t.id), ['t1', 't2']);
  });

  test('a server refusing derivedfrom is searched without classes', () async {
    final lib = FakeLibrary(refuseDerivedFrom: true);
    final r = await lib.search.search('cherkassky');
    expect(r.artists.map((a) => a.id), ['ar1']);
    expect(r.albums.map((a) => a.id), ['al1']);
    expect(r.tracks.map((t) => t.id), ['t1', 't2']);
    expect(lib.criteria.last, isNot(contains('derivedfrom')));
  });

  test('a server without search reports it and finds nothing', () async {
    final lib = FakeLibrary(caps: '');
    expect(await lib.search.supported, isFalse);
    expect((await lib.search.search('berg')).isEmpty, isTrue);
    expect(lib.criteria, isEmpty);
  });

  test('only searchable properties are used', () async {
    final lib = FakeLibrary(caps: 'upnp:class,dc:title');
    await lib.search.search('berg');
    expect(lib.criteria, everyElement(isNot(contains('upnp:artist'))));
  });
}
