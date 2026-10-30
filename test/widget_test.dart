import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/pages/browse_page.dart';
import 'package:minstrel/pages/settings_page.dart';
import 'package:minstrel/widgets/cover_art.dart';
import 'package:minstrel/widgets/track_info.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('formatDuration', () {
    expect(formatDuration(const Duration(minutes: 4, seconds: 5)), '4:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(formatDuration(null), '');
  });

  test('filter text ignores case and accents', () {
    expect(foldForSearch('Dvořák'), 'dvorak');
    expect(foldForSearch('BEYONCÉ'), 'beyonce');
    expect(foldForSearch('Straße Œuvre'), 'strasse oeuvre');
  });

  testWidgets('settings show the version and build', (tester) async {
    PackageInfo.setMockInitialValues(
        appName: 'Minstrel', packageName: 'p', version: '1.0.1', buildNumber: '11', buildSignature: '');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AppVersion())));
    await tester.pump();
    expect(find.text('Minstrel 1.0.1 (build 11)'), findsOneWidget);
  });

  test('track info lists the tags and the format', () {
    const xml = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="1" parentID="0"><dc:title>Sonata</dc:title><upnp:artist>Shura Cherkassky</upnp:artist>'
        '<upnp:artist role="Composer">Alban Berg</upnp:artist><upnp:album>Recital</upnp:album>'
        '<upnp:originalTrackNumber>6</upnp:originalTrackNumber><upnp:albumArtist>Cherkassky</upnp:albumArtist>'
        '<res duration="0:10:23" size="36223490" bitsPerSample="16" sampleFrequency="44100" nrAudioChannels="2" '
        'protocolInfo="http-get:*:audio/flac:*">http://s/6.flac</res>'
        '<res protocolInfo="http-get:*:audio/mpeg:*" bitrate="40000">http://s/6.mp3</res>'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class></item></DIDL-Lite>';
    final item = parseDidlLite(xml).single as DidlItem;
    expect(Map.fromEntries(trackInfoRows(item).map((r) => MapEntry(r.$1, r.$2))), {
      'Artist': 'Shura Cherkassky',
      'Composer': 'Alban Berg',
      'Album': 'Recital',
      'Track': '6',
      'Duration': '10:23',
      'Format': 'FLAC 16/44.1',
      'Type': 'audio/flac',
      'Sample rate': '44100 Hz',
      'Bit depth': '16 bit',
      'Channels': '2',
      'Size': '34.5 MB',
      'URL': 'http://s/6.flac',
      'Also as': 'MP3 320k',
      'Album artist': 'Cherkassky',
    });
  });
}
