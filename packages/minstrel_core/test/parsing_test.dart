import 'dart:io';

import 'package:minstrel_core/minstrel_core.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// Extracts the DIDL-Lite string from a Browse SOAP response.
String didlFromEnvelope(String envelope) => XmlDocument.parse(envelope)
    .descendantElements
    .firstWhere((e) => e.name.local == 'Result')
    .innerText;

void main() {
  group('device description', () {
    test('MinimServer', () {
      final loc = Uri.parse('http://192.168.1.9:9791/x/Upnp/device.xml');
      final devices = UpnpDevice.parseAll(fixture('minimserver-device.xml'), loc);
      expect(devices, hasLength(1));
      final d = devices.single;
      expect(d.isMediaServer, isTrue);
      expect(d.friendlyName, 'MinimServer[minim]');
      expect(d.service('ContentDirectory')!.controlUrl.toString(),
          'http://192.168.1.9:9791/f6417dbf-cc85-4560-aa2e-72bbc55f770e/upnp.org-ContentDirectory-1/control');
      expect(d.bestIcon!.width, 120);
      expect(d.bestIcon!.mimeType, 'image/png');
    });

    test('Cambridge CXNv2 renderer', () {
      final loc = Uri.parse('http://192.168.1.178:8050/x/description.xml');
      final d = UpnpDevice.parseAll(fixture('cxnv2-device.xml'), loc).single;
      expect(d.isMediaRenderer, isTrue);
      expect(d.service('AVTransport'), isNotNull);
      expect(d.service('RenderingControl'), isNotNull);
      expect(d.service('ConnectionManager'), isNotNull);
    });
  });

  group('DIDL-Lite', () {
    test('MinimServer root containers', () {
      final objs = parseDidlLite(didlFromEnvelope(fixture('minimserver-browse-root.xml')));
      expect(objs, everyElement(isA<DidlContainer>()));
      expect(objs.map((o) => o.title), containsAll(['Composer', 'Artist', 'Recently Added']));
      expect(objs.first.albumArt!.host, '192.168.1.9');
    });

    test('classical item with composer role and FLAC resource', () {
      final objs = parseDidlLite(didlFromEnvelope(fixture('minimserver-browse-items.xml')));
      final item = objs.whereType<DidlItem>().first;
      expect(item.title, 'Piano Sonata, Op. 1 - Allegro Moderato [Live]');
      expect(item.composer, 'Alban Berg');
      expect(item.performer, 'Shura Cherkassky');
      expect(item.trackNumber, 6);
      expect(item.isAudio, isTrue);
      final res = item.resources.single;
      expect(res.mimeType, 'audio/flac');
      expect(res.isLossless, isTrue);
      expect(res.formatLabel, 'FLAC 16/44.1');
      expect(res.duration, const Duration(minutes: 10, seconds: 23, milliseconds: 960));
      expect(res.uri.path, contains('Piano*20Sonata'));
    });

    test('item metadata round-trips as standalone DIDL-Lite', () {
      final item = parseDidlLite(didlFromEnvelope(fixture('minimserver-browse-items.xml')))
          .whereType<DidlItem>()
          .first;
      final again = parseDidlLite(item.toDidlLite()).single as DidlItem;
      expect(again.id, item.id);
      expect(again.composer, 'Alban Berg');
      expect(again.resources.single.uri, item.resources.single.uri);
    });

    test('vendor namespace declared on the root survives extraction', () {
      const xml = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:pv="http://www.pv.com/pvns/">'
          '<item id="1" parentID="0"><dc:title>T</dc:title><pv:extension>x</pv:extension></item>'
          '</DIDL-Lite>';
      final item = parseDidlLite(xml).single as DidlItem;
      expect(() => XmlDocument.parse(item.toDidlLite()), returnsNormally);
    });
  });

  group('protocolInfo and resource selection', () {
    final cxnSinks = ProtocolInfo.parseList(XmlDocument.parse(fixture('cxnv2-protocolinfo.xml'))
        .descendantElements
        .firstWhere((e) => e.name.local == 'Sink')
        .innerText);

    DidlResource res(String protocolInfo, {int? bitrate, int? rate, int? bits}) =>
        DidlResource(
          uri: Uri.parse('http://s/$protocolInfo'),
          protocolInfo: ProtocolInfo.parse(protocolInfo),
          bitrate: bitrate,
          sampleFrequency: rate,
          bitsPerSample: bits,
        );

    DidlItem item(List<DidlResource> resources) => DidlItem(
          id: '1', parentId: '0', title: 't', upnpClass: 'object.item.audioItem.musicTrack',
          artists: const [], creators: const [], album: null, genre: null, date: null,
          albumArt: null, rawXml: '<item/>', resources: resources, trackNumber: null);

    test('aliases match: audio/x-flac resource on an audio/flac sink', () {
      expect(ProtocolInfo.parse('http-get:*:audio/x-flac:*')!.playableBy(
          ProtocolInfo.parse('http-get:*:audio/flac:*')!), isTrue);
    });

    test('L16 must agree on rate and channels', () {
      final sink = ProtocolInfo.parse('http-get:*:audio/L16;rate=44100;channels=2:*')!;
      expect(ProtocolInfo.parse('http-get:*:audio/L16;rate=44100;channels=2:*')!.playableBy(sink), isTrue);
      expect(ProtocolInfo.parse('http-get:*:audio/L16;rate=96000;channels=2:*')!.playableBy(sink), isFalse);
    });

    test('CXNv2 accepts FLAC; Apple local player has no Ogg', () {
      final flac = res('http-get:*:audio/x-flac:DLNA.ORG_OP=01');
      final ogg = res('http-get:*:audio/ogg:*');
      expect(ResourceSelector.select(item([flac]), cxnSinks), same(flac));
      expect(ResourceSelector.select(item([ogg]), LocalSinks.apple), isNull);
      expect(ResourceSelector.select(item([ogg]), LocalSinks.android), same(ogg));
    });

    test('best prefers hi-res lossless; data saver prefers the transcode', () {
      final hires = res('http-get:*:audio/flac:*', rate: 96000, bits: 24);
      final cd = res('http-get:*:audio/flac:*', rate: 44100, bits: 16);
      final mp3 = res('http-get:*:audio/mpeg:*', bitrate: 40000);
      final i = item([cd, mp3, hires]);
      expect(ResourceSelector.select(i, LocalSinks.android), same(hires));
      expect(ResourceSelector.select(i, LocalSinks.android,
          preference: QualityPreference.dataSaver), same(mp3));
    });

    test('rtsp and unknown protocols are skipped', () {
      final rtsp = res('rtsp-rtp-udp:*:audio/mpeg:*');
      expect(ResourceSelector.select(item([rtsp]), cxnSinks), isNull);
    });
  });

  test('UPnP time parsing and formatting', () {
    expect(parseUpnpDuration('0:04:23.974'), const Duration(minutes: 4, seconds: 23, milliseconds: 974));
    expect(parseUpnpDuration('01:00:00'), const Duration(hours: 1));
    expect(parseUpnpDuration('NOT_IMPLEMENTED'), isNull);
    expect(parseUpnpDuration(''), isNull);
    expect(formatUpnpDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });
}
