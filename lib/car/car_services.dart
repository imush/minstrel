import 'package:audio_service/audio_service.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../playback/audio_handler.dart';
import 'car_library.dart';

/// The car library's view of the media servers the app knows.
class RegistrySource implements CarSource {
  final DeviceRegistry registry;

  RegistrySource(this.registry);

  @override
  List<({String udn, String name, String? via})> get servers =>
      [for (final s in registry.servers) (udn: s.udn, name: s.name, via: s.via)];

  @override
  Stream<void> get changes => registry.changes;

  ContentDirectory _cd(String udn) {
    final s = registry.server(udn);
    if (s == null) throw StateError('server $udn is not available');
    return s.contentDirectory;
  }

  @override
  Future<BrowseResult> browse(String udn, String objectId, {int start = 0, int count = 200}) =>
      _cd(udn).browse(objectId, start: start, count: count);

  @override
  Future<BrowseResult> search(String udn, String criteria, {int count = 50}) =>
      _cd(udn).search(_searchRoot, criteria, count: count);

  @override
  Future<List<DidlItem>> tracks(String udn, String containerId) =>
      _cd(udn).collectTracks(containerId, maxTracks: 500, maxRequests: 50);

  static const _searchRoot = '0';
}

/// Plays for the car: always on this phone, since the car's speakers are
/// connected to it, never on a renderer at home.
class PhonePlayer implements CarPlayer {
  final MinstrelAudioHandler handler;

  PhonePlayer(this.handler);

  @override
  Future<void> playItems(List<DidlItem> items, int start) async {
    if (!handler.output.isLocal) await handler.switchOutput(handler.localOutput);
    await handler.playItems(items, start);
  }

  @override
  Future<bool> resume() async {
    if (handler.entries.isEmpty) return false;
    if (!handler.output.isLocal) await handler.switchOutput(handler.localOutput);
    await handler.play();
    return true;
  }
}

class PrefsHistory implements CarHistoryStore {
  static const _key = 'carHistory';
  final SharedPreferences prefs;

  PrefsHistory(this.prefs);

  @override
  List<String> load() => prefs.getStringList(_key) ?? const [];

  @override
  Future<void> save(List<String> entries) => prefs.setStringList(_key, entries);
}

/// Android Auto shows artwork only from content:// URIs, which the app's
/// AlbumArtProvider serves by fetching the image over the network.
Uri? carArt(Uri? art) => art == null || (art.scheme != 'http' && art.scheme != 'https')
    ? art
    : Uri(scheme: 'content', host: 'org.minstrelplayer.minstrel.art', path: '/art', queryParameters: {'u': '$art'});

MediaItem carMediaItem(CarNode n) => MediaItem(
      id: n.id,
      title: n.title,
      displaySubtitle: n.subtitle,
      artist: n.subtitle,
      artUri: carArt(n.art),
      // Android has one flag: an entry is either a folder or playable.
      playable: n.playable && !n.browsable,
    );
