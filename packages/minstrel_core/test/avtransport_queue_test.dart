import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

/// A minimal AVTransport renderer behind a MockClient. [finishTrack]
/// simulates the current track ending: with a next URI set it moves on
/// gaplessly, otherwise it stops.
class FakeRenderer {
  String state = 'NO_MEDIA_PRESENT';
  String? current;
  String? next;
  final calls = <String>[];

  late final client = MockClient((req) async {
    final action = req.headers['SOAPACTION']!.split('#').last.replaceAll('"', '');
    calls.add(action);
    final body = XmlDocument.parse(req.body);
    String arg(String n) =>
        body.descendantElements.firstWhere((e) => e.name.local == n).innerText;
    var out = '';
    switch (action) {
      case 'SetAVTransportURI':
        current = arg('CurrentURI');
        next = null;
        state = 'STOPPED';
      case 'SetNextAVTransportURI':
        next = arg('NextURI').isEmpty ? null : arg('NextURI');
      case 'Play':
        state = 'PLAYING';
      case 'Stop':
        state = 'STOPPED';
      case 'GetTransportInfo':
        out = '<CurrentTransportState>$state</CurrentTransportState>';
      case 'GetPositionInfo':
        out = '<Track>1</Track><TrackDuration>0:03:00</TrackDuration>'
            '<RelTime>0:00:10</RelTime><TrackURI>${current ?? ''}</TrackURI>';
    }
    return http.Response(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
        '<u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">$out'
        '</u:${action}Response></s:Body></s:Envelope>',
        200);
  });

  void finishTrack() {
    if (next != null) {
      current = next;
      next = null;
    } else {
      state = 'STOPPED';
    }
  }
}

QueueEntry entry(int n) {
  final uri = Uri.parse('http://server/track$n.flac');
  return QueueEntry(
    DidlItem(
        id: '$n', parentId: '0', title: 'Track $n', upnpClass: 'object.item.audioItem.musicTrack',
        artists: const [], creators: const [], album: null, genre: null, date: null,
        albumArt: null, rawXml: '<item id="$n"/>', resources: [DidlResource(uri: uri)],
        trackNumber: n),
    DidlResource(uri: uri),
  );
}

void main() {
  late FakeRenderer r;

  AvTransportQueue session({required bool setNext}) => AvTransportQueue(
        transport: AVTransport(
            SoapClient(r.client),
            UpnpService(
              serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
              serviceId: '',
              controlUrl: Uri.parse('http://renderer/avt'),
              eventSubUrl: Uri.parse('http://renderer/evt'),
              scpdUrl: Uri.parse('http://renderer/scpd'),
            )),
        sinks: const [],
        supportsSetNext: setNext,
        pollInterval: const Duration(milliseconds: 10),
      );

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  setUp(() => r = FakeRenderer());

  test('gapless: queues the next track and follows the renderer onto it', () async {
    final s = session(setNext: true);
    await s.playQueue([entry(1), entry(2), entry(3)]);
    expect(r.current, 'http://server/track1.flac');
    expect(r.next, 'http://server/track2.flac');

    r.finishTrack();
    await settle();
    expect(s.index, 1);
    expect(r.next, 'http://server/track3.flac', reason: 'queues the one after');
    expect(r.calls.where((c) => c == 'SetAVTransportURI'), hasLength(1),
        reason: 'renderer moved on by itself; no restart');

    r.finishTrack();
    await settle();
    expect(s.index, 2);
    r.finishTrack(); // end of queue: renderer stops
    await settle();
    expect(s.current.state, TransportState.stopped);
    expect(r.calls.where((c) => c == 'SetAVTransportURI'), hasLength(1));
    await s.dispose();
  });

  test('without SetNext, starts the next track when the renderer stops', () async {
    final s = session(setNext: false);
    await s.playQueue([entry(1), entry(2)]);
    await settle(); // see PLAYING first
    r.finishTrack();
    await settle();
    expect(s.index, 1);
    expect(r.current, 'http://server/track2.flac');
    expect(r.state, 'PLAYING');
    expect(r.calls, isNot(contains('SetNextAVTransportURI')));
    await s.dispose();
  });

  test('user stop does not advance', () async {
    final s = session(setNext: false);
    await s.playQueue([entry(1), entry(2)]);
    await settle();
    await s.stop();
    await settle();
    expect(s.index, 0);
    expect(r.current, 'http://server/track1.flac');
    await s.dispose();
  });

  test('detects another control point taking over', () async {
    final s = session(setNext: true);
    await s.playQueue([entry(1)]);
    r.current = 'http://elsewhere/other.mp3';
    await settle();
    expect(s.current.detached, isTrue);
    await s.dispose();
  });

  test('editing the queue re-sends the next track only when it changed', () async {
    final s = session(setNext: true);
    await s.playQueue([entry(1), entry(2), entry(3)]);
    expect(r.next, 'http://server/track2.flac');

    await s.insert(1, [entry(9)]); // play next
    expect(r.next, 'http://server/track9.flac');
    final sets = r.calls.where((c) => c == 'SetNextAVTransportURI').length;
    await s.insert(s.queue.length, [entry(7)]); // add to end
    expect(r.calls.where((c) => c == 'SetNextAVTransportURI'), hasLength(sets));

    await s.removeAt(1); // remove the upcoming track
    expect(r.next, 'http://server/track2.flac');
    await s.move(3, 1); // move track 7 up next
    expect(r.next, 'http://server/track7.flac');
    expect(s.queue.map((e) => e.item.id), ['1', '7', '2', '3']);
    await s.dispose();
  });

  test('removing the playing track starts the next one', () async {
    final s = session(setNext: true);
    await s.playQueue([entry(1), entry(2), entry(3)]);
    await s.removeAt(0);
    expect(r.current, 'http://server/track2.flac');
    expect(s.index, 0);
    await s.dispose();
  });

  test('after an app restart, follows a saved queue containing the current track', () async {
    final saved = [entry(1), entry(2), entry(3)];
    final first = session(setNext: true);
    await first.playQueue(saved);
    r.finishTrack(); // now on track 2, with nothing queued after it
    await first.dispose();

    final again = session(setNext: true);
    expect(await again.attach(saved), isTrue);
    expect(again.index, 1);
    expect(r.next, 'http://server/track3.flac', reason: 'next track handed over again');
    expect(r.calls.where((c) => c == 'SetAVTransportURI'), hasLength(1), reason: 'not restarted');
    await again.dispose();
  });

  test('does not take over a renderer playing something else', () async {
    r.current = 'http://elsewhere/other.mp3';
    r.state = 'PLAYING';
    final s = session(setNext: true);
    expect(await s.attach([entry(1)]), isFalse);
    expect(r.calls, isNot(contains('SetNextAVTransportURI')));
    await s.dispose();
  });
}
