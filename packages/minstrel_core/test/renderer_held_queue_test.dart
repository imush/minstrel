import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

/// A renderer-side playlist shared by the OpenHome and PlaylistExtension
/// fakes: ids, URIs, a current track, and a transport state.
class FakeList {
  final ids = <int>[];
  final uris = <int, String>{};
  final metadata = <int, String>{};
  int current = 0;
  String state = 'Stopped';
  int _nextId = 100;
  final calls = <String>[];

  int insert(int after, String uri, [String md = '']) {
    final id = _nextId++;
    metadata[id] = md;
    final at = after == 0 ? 0 : ids.indexOf(after) + 1;
    ids.insert(at, id);
    uris[id] = uri;
    return id;
  }

  void remove(int id) {
    final i = ids.indexOf(id);
    ids.remove(id);
    // Like real renderers: deleting the current track moves to the next.
    if (id == current) current = i < ids.length ? ids[i] : 0;
  }

  void step(int delta) {
    final i = ids.indexOf(current) + delta;
    if (i >= 0 && i < ids.length) current = ids[i];
  }

  /// The current track ends; a renderer-held queue moves on by itself.
  void finishTrack() {
    final i = ids.indexOf(current);
    if (i + 1 < ids.length) {
      current = ids[i + 1];
    } else {
      state = 'Stopped';
    }
  }

  List<String> get order => [for (final id in ids) uris[id]!.split('/').last];
}

http.Response envelope(String action, String serviceType, String out) => http.Response(
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
    '<u:${action}Response xmlns:u="$serviceType">$out</u:${action}Response></s:Body></s:Envelope>',
    200);

String b64(List<int> ids) {
  final d = ByteData(ids.length * 4);
  for (var i = 0; i < ids.length; i++) {
    d.setUint32(i * 4, ids[i]);
  }
  return base64.encode(d.buffer.asUint8List());
}

class FakeOpenHome {
  final list = FakeList();
  int sourceIndex = 0; // starts on Radio

  late final client = MockClient((req) async {
    final soapAction = req.headers['SOAPACTION']!.replaceAll('"', '');
    final type = soapAction.split('#').first;
    final action = soapAction.split('#').last;
    list.calls.add(action);
    final body = XmlDocument.parse(req.body);
    String arg(String n) => body.descendantElements.firstWhere((e) => e.name.local == n).innerText;
    var out = '';
    switch (action) {
      case 'DeleteAll':
        list.ids.clear();
        list.current = 0;
        list.state = 'Stopped';
      case 'Insert':
        out = '<NewId>${list.insert(int.parse(arg('AfterId')), arg('Uri'), arg('Metadata'))}</NewId>';
      case 'IdArray':
        out = '<Token>1</Token><Array>${b64(list.ids)}</Array>';
      case 'ReadList':
        final ids = arg('IdList').split(' ').map(int.parse);
        out = '<TrackList>${const HtmlEscape().convert('<TrackList>${[
          for (final id in ids)
            '<Entry><Id>$id</Id><Uri>${list.uris[id]}</Uri>'
                '<Metadata>${const HtmlEscape().convert(list.metadata[id]!)}</Metadata></Entry>'
        ].join()}</TrackList>')}</TrackList>';
      case 'DeleteId':
        list.remove(int.parse(arg('Value')));
      case 'SeekId':
        list.current = int.parse(arg('Value'));
        list.state = 'Playing';
      case 'Play':
        list.state = 'Playing';
      case 'Pause':
        list.state = 'Paused';
      case 'Stop':
        list.state = 'Stopped';
      case 'TransportState':
        out = '<Value>${list.state}</Value>';
      case 'Id':
        out = '<Value>${list.current}</Value>';
      case 'Time':
        out = '<TrackCount>1</TrackCount><Duration>180</Duration><Seconds>10</Seconds>';
      case 'SourceXml':
        out = '<Value>${const HtmlEscape().convert('<SourceList>'
            '<Source><Name>Radio</Name><Type>Radio</Type><Visible>true</Visible></Source>'
            '<Source><Name>Playlist</Name><Type>Playlist</Type><Visible>true</Visible></Source>'
            '</SourceList>')}</Value>';
      case 'SourceIndex':
        out = '<Value>$sourceIndex</Value>';
      case 'SetSourceIndex':
        sourceIndex = int.parse(arg('Value'));
    }
    return envelope(action, type, out);
  });
}

class FakeStreamMagic {
  final list = FakeList();

  late final client = MockClient((req) async {
    final soapAction = req.headers['SOAPACTION']!.replaceAll('"', '');
    final type = soapAction.split('#').first;
    final action = soapAction.split('#').last;
    list.calls.add(action);
    final body = XmlDocument.parse(req.body);
    String arg(String n) => body.descendantElements.firstWhere((e) => e.name.local == n).innerText;
    var out = '';
    switch (action) {
      case 'DeleteAll':
        list.ids.clear();
        list.current = 0;
      case 'Insert':
        out = '<aNewId>${list.insert(int.parse(arg('aAfterId')), arg('aUri'), arg('aMetaData'))}</aNewId>';
      case 'IdArray':
        out = '<aIdArrayToken>1</aIdArrayToken><aIdArray>${b64(list.ids)}</aIdArray>';
      case 'ReadList':
        // As on the CXNv2: comma-separated ids, 'l'-suffixed in the reply,
        // and metadata trimmed to a <res> with no URL.
        final ids = arg('aIdList').split(',').map(int.parse);
        out = '<aMetaDataList>${const HtmlEscape().convert('<MetaDataList>${[
          for (final id in ids)
            '<Entry><Id>${id}l</Id><Uri>${list.uris[id]}</Uri><MetaData>${const HtmlEscape().convert(
                '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
                'xmlns:dc="http://purl.org/dc/elements/1.1/"><item><dc:title>Stored $id</dc:title>'
                '<res duration="0:03:00.000"></res><upnp:class xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
                'object.item.audioItem.musicTrack</upnp:class></item></DIDL-Lite>')}</MetaData></Entry>'
        ].join()}</MetaDataList>')}</aMetaDataList>';
      case 'Delete':
        list.remove(int.parse(arg('aId')));
      case 'Play':
        // Observed on a CXNv2: Play from stopped starts at the first entry.
        if (list.state == 'Stopped') list.current = list.ids.first;
        list.state = 'Playing';
      case 'Stop':
        list.state = 'Stopped';
      case 'Next':
        list.step(1);
      case 'Previous':
        list.step(-1);
      case 'GetTransportInfo':
        out = '<CurrentTransportState>${list.state == 'Playing' ? 'PLAYING' : 'STOPPED'}</CurrentTransportState>';
      case 'GetPositionInfo':
        out = '<Track>1</Track><TrackDuration>0:03:00</TrackDuration><RelTime>0:00:10</RelTime>'
            '<TrackURI>${list.uris[list.current] ?? ''}</TrackURI>';
    }
    return envelope(action, type, out);
  });
}

UpnpService svc(String type) => UpnpService(
    serviceType: type,
    serviceId: '',
    controlUrl: Uri.parse('http://renderer/ctl'),
    eventSubUrl: Uri.parse('http://renderer/evt'),
    scpdUrl: Uri.parse('http://renderer/scpd'));

QueueEntry entry(int n) {
  final uri = Uri.parse('http://server/track$n.flac');
  return QueueEntry(
    DidlItem(
        id: '$n', parentId: '0', title: 'Track $n', upnpClass: 'object.item.audioItem.musicTrack',
        artists: const [], creators: const [], album: null, genre: null, date: null,
        albumArt: null,
        rawXml: '<item id="$n" parentID="0"><dc:title>Track $n</dc:title>'
            '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
            '<upnp:artist role="Composer">Composer $n</upnp:artist>'
            '<res protocolInfo="http-get:*:audio/flac:*">$uri</res></item>',
        resources: [DidlResource(uri: uri)],
        trackNumber: n),
    DidlResource(uri: uri),
  );
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  group('OpenHome', () {
    late FakeOpenHome r;
    late RendererHeldQueue q;

    setUp(() {
      r = FakeOpenHome();
      final soap = SoapClient(r.client);
      q = RendererHeldQueue(
        OpenHomeBackend(
          OhPlaylist(soap, svc('urn:av-openhome-org:service:Playlist:1')),
          time: OhTime(soap, svc('urn:av-openhome-org:service:Time:1')),
          product: OhProduct(soap, svc('urn:av-openhome-org:service:Product:1')),
        ),
        pollInterval: const Duration(milliseconds: 10),
      );
    });
    tearDown(() => q.dispose());

    test('loads from the start track, switches to the Playlist source, plays on its own', () async {
      await q.playQueue([entry(1), entry(2), entry(3), entry(4)], startIndex: 1);
      await settle();
      expect(r.sourceIndex, 1, reason: 'switched from Radio to Playlist');
      expect(r.list.order, ['track2.flac', 'track3.flac', 'track4.flac']);
      expect(q.index, 1);
      expect(q.heldByRenderer, isTrue);

      final seeksBefore = r.list.calls.where((c) => c == 'SeekId').length;
      r.list.finishTrack();
      await settle();
      expect(q.index, 2, reason: 'followed the renderer');
      expect(r.list.calls.where((c) => c == 'SeekId').length, seeksBefore,
          reason: 'the renderer advanced without help');
    });

    test('skip within the loaded list uses SeekId; going back before it reloads', () async {
      await q.playQueue([entry(1), entry(2), entry(3)], startIndex: 1);
      await settle();
      await q.skipTo(2);
      expect(r.list.uris[r.list.current], endsWith('track3.flac'));
      expect(r.list.calls.where((c) => c == 'DeleteAll'), hasLength(1));

      await q.skipTo(0);
      await settle();
      expect(r.list.calls.where((c) => c == 'DeleteAll'), hasLength(2));
      expect(r.list.order, ['track1.flac', 'track2.flac', 'track3.flac']);
      expect(q.index, 0);
    });

    test('play next, add to queue, remove and move reach the renderer', () async {
      await q.playQueue([entry(1), entry(2), entry(3)]);
      await settle();
      await q.insert(1, [entry(9)]); // play next
      await q.insert(q.queue.length, [entry(7)]); // add to queue
      expect(r.list.order, ['track1.flac', 'track9.flac', 'track2.flac', 'track3.flac', 'track7.flac']);
      await q.removeAt(2);
      expect(r.list.order, ['track1.flac', 'track9.flac', 'track3.flac', 'track7.flac']);
      await q.move(3, 1);
      expect(r.list.order, ['track1.flac', 'track7.flac', 'track9.flac', 'track3.flac']);
      expect(q.queue.map((e) => e.item.id), ['1', '7', '9', '3']);
      expect(q.index, 0);

      r.list.finishTrack();
      await settle();
      expect(q.index, 1, reason: 'renderer moved on to the moved track');
    });

    test('edits before the loaded part stay on the phone', () async {
      await q.playQueue([entry(1), entry(2), entry(3)], startIndex: 2);
      await settle();
      expect(r.list.order, ['track3.flac']);
      await q.insert(0, [entry(8)]);
      expect(r.list.order, ['track3.flac']);
      expect(q.index, 3);
      await q.removeAt(1);
      expect(q.index, 2);
      await q.skipTo(0);
      await settle();
      expect(r.list.order, ['track8.flac', 'track2.flac', 'track3.flac']);
    });

    test('edits made while the list is still being loaded land in order', () async {
      final many = [for (var i = 1; i <= 20; i++) entry(i)];
      await q.playQueue(many);
      await q.insert(1, [entry(99)]); // races the background fill
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(r.list.order.take(3), ['track1.flac', 'track99.flac', 'track2.flac']);
      expect(r.list.order, hasLength(21));
    });

    test('after an app restart, a new session picks up the running queue', () async {
      final saved = [entry(1), entry(2), entry(3)];
      await q.playQueue(saved, startIndex: 1);
      await settle();
      r.list.finishTrack(); // renderer moves to track 3 while the app is gone
      await q.dispose();

      final again = RendererHeldQueue(q.backend, pollInterval: const Duration(milliseconds: 10));
      addTearDown(again.dispose);
      expect(await again.attach(saved), isTrue);
      expect(again.queue.map((e) => e.item.id), ['1', '2', '3'], reason: 'saved copy, all of it');
      expect(again.index, 2);
      expect(again.queue[2].item, same(saved[2].item), reason: 'the saved copy, not a re-parse');
      expect(r.list.calls.where((c) => c == 'DeleteAll'), hasLength(1), reason: 'not reloaded');
    });

    test('without a saved queue, the renderer list is used as is', () async {
      await q.playQueue([entry(1), entry(2)]);
      await settle();
      final other = RendererHeldQueue(q.backend, pollInterval: const Duration(milliseconds: 10));
      addTearDown(other.dispose);
      expect(await other.attach(const []), isTrue);
      expect(other.queue.map((e) => e.item.title), ['Track 1', 'Track 2']);
      expect(other.queue[0].resource.uri.toString(), 'http://server/track1.flac');
    });

    test('a list changed by another app wins over the saved queue', () async {
      await q.playQueue([entry(1), entry(2)]);
      await settle();
      r.list.insert(r.list.ids.last, 'http://server/other.flac', '');
      final again = RendererHeldQueue(q.backend, pollInterval: const Duration(milliseconds: 10));
      addTearDown(again.dispose);
      expect(await again.attach([entry(1), entry(2)]), isTrue);
      expect(again.queue, hasLength(3));
      expect(again.queue.last.item.title, 'other', reason: 'title from the URL');
    });

    test('notices another control point replacing the playlist', () async {
      await q.playQueue([entry(1), entry(2)]);
      await settle();
      r.list.current = 9999;
      await settle();
      expect(q.current.detached, isTrue);
    });
  });

  group('PlaylistExtension (StreamMagic)', () {
    late FakeStreamMagic r;
    late RendererHeldQueue q;

    setUp(() {
      r = FakeStreamMagic();
      final soap = SoapClient(r.client);
      q = RendererHeldQueue(
        PlaylistExtensionBackend(
          PlaylistExtension(soap, svc('urn:UuVol-com:service:PlaylistExtension:1')),
          AVTransport(soap, svc('urn:schemas-upnp-org:service:AVTransport:1')),
        ),
        pollInterval: const Duration(milliseconds: 10),
      );
    });
    tearDown(() => q.dispose());

    test('starts at the requested track and follows by URI', () async {
      await q.playQueue([entry(1), entry(2), entry(3)], startIndex: 1);
      await settle();
      expect(r.list.uris[r.list.current], endsWith('track2.flac'));
      r.list.finishTrack();
      await settle();
      expect(q.index, 2);
      expect(r.list.calls, isNot(contains('Seek')), reason: 'TRACK_NR seek is unreliable');
    });

    test('picks up a running queue from the trimmed metadata the CXNv2 stores', () async {
      await q.playQueue([entry(1), entry(2)]);
      await settle();
      final other = RendererHeldQueue(q.backend, pollInterval: const Duration(milliseconds: 10));
      addTearDown(other.dispose);
      expect(await other.attach(const []), isTrue);
      expect(other.queue.map((e) => e.item.title), ['Stored 100', 'Stored 101']);
      expect(other.queue[0].resource.duration, const Duration(minutes: 3));
      expect(other.queue[1].resource.uri.toString(), 'http://server/track2.flac');
    });

    test('short jumps step with Next/Previous', () async {
      await q.playQueue([entry(1), entry(2), entry(3), entry(4)]);
      await settle();
      await q.skipTo(2);
      expect(r.list.uris[r.list.current], endsWith('track3.flac'));
      await q.skipTo(1);
      expect(r.list.uris[r.list.current], endsWith('track2.flac'));
      expect(r.list.calls.where((c) => c == 'DeleteAll'), hasLength(1));
    });
  });

  group('strategy selection', () {
    final client = http.Client();
    final soap = SoapClient(client);

    test('Cambridge CXNv2 uses its playlist extension', () {
      final devices = UpnpDevice.parseAll(
          File('test/fixtures/cxnv2-device.xml').readAsStringSync(), Uri.parse('http://r/d.xml'));
      final r = MediaRenderer.fromDevices(devices, soap, client)!;
      expect(r.strategy, QueueStrategy.playlistExtension);
      expect(r.holdsQueue, isTrue);
    });

    test('OpenHome wins, even when its services are on an embedded device', () {
      const xml = '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
          '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
          '<friendlyName>Living Room</friendlyName><UDN>uuid:avt</UDN><serviceList>'
          '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
          '<controlURL>/avt</controlURL><eventSubURL>/e</eventSubURL><SCPDURL>/s</SCPDURL></service>'
          '</serviceList><deviceList><device>'
          '<deviceType>urn:av-openhome-org:device:Source:1</deviceType>'
          '<friendlyName>Living Room:Streamer</friendlyName><UDN>uuid:oh</UDN><serviceList>'
          '<service><serviceType>urn:av-openhome-org:service:Playlist:1</serviceType>'
          '<controlURL>/pl</controlURL><eventSubURL>/e</eventSubURL><SCPDURL>/s</SCPDURL></service>'
          '</serviceList></device></deviceList></device></root>';
      final r = MediaRenderer.fromDevices(UpnpDevice.parseAll(xml, Uri.parse('http://r/d.xml')), soap, client)!;
      expect(r.strategy, QueueStrategy.openHome);
      expect(r.name, 'Living Room');
      expect(r.udns, {'uuid:avt', 'uuid:oh'});
    });

    test('a plain AVTransport renderer is phone-held', () {
      const xml = '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
          '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
          '<friendlyName>TV</friendlyName><UDN>uuid:tv</UDN><serviceList>'
          '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
          '<controlURL>/avt</controlURL><eventSubURL>/e</eventSubURL><SCPDURL>/s</SCPDURL></service>'
          '</serviceList></device></root>';
      final r = MediaRenderer.fromDevices(UpnpDevice.parseAll(xml, Uri.parse('http://r/d.xml')), soap, client)!;
      expect(r.strategy, QueueStrategy.avTransport);
      expect(r.holdsQueue, isFalse);
    });
  });

  test('IdArray decoding matches what the CXNv2 returned', () {
    expect(decodeIdArray(b64([13998752, 8380304])), [13998752, 8380304]);
    expect(decodeIdArray(''), isEmpty);
  });

  group('queue snapshot', () {
    test('round-trips entries with full metadata', () {
      final snap = QueueSnapshot(
          outputId: 'uuid:x', entries: [entry(1), entry(2)], index: 1, position: const Duration(seconds: 42));
      final back = QueueSnapshot.decode(snap.encode())!;
      expect(back.outputId, 'uuid:x');
      expect(back.index, 1);
      expect(back.position, const Duration(seconds: 42));
      expect(back.entries.map((e) => e.item.composer), ['Composer 1', 'Composer 2']);
      expect(back.entries[1].resource.uri.toString(), 'http://server/track2.flac');
      expect(back.entries[1].resource.mimeType, 'audio/flac');
    });

    test('garbage or another version decodes to null', () {
      expect(QueueSnapshot.decode('not json'), isNull);
      expect(QueueSnapshot.decode('{"v": 99}'), isNull);
    });
  });
}
