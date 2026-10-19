import 'dart:async';
import 'dart:convert';

import 'package:minstrel_core/minstrel_core.dart';

/// One entry in the car's menus: a folder to open, a track to play, or both.
class CarNode {
  final String id;
  final String title;
  final String? subtitle;
  final Uri? art;
  final bool browsable;
  final bool playable;

  const CarNode(this.id, this.title,
      {this.subtitle, this.art, this.browsable = false, this.playable = false});

  @override
  String toString() => 'CarNode($id, $title)';
}

/// What the car library reads: the media servers and their content.
abstract class CarSource {
  List<({String udn, String name, String? via})> get servers;

  /// Fires when servers may have come or gone.
  Stream<void> get changes;
  Future<BrowseResult> browse(String udn, String objectId, {int start = 0, int count = 200});
  Future<BrowseResult> search(String udn, String criteria, {int count = 50});

  /// Every audio track under a container, for playing a whole album.
  Future<List<DidlItem>> tracks(String udn, String containerId);
}

/// What the car library controls.
abstract class CarPlayer {
  Future<void> playItems(List<DidlItem> items, int start);

  /// Resumes the current queue; false when there is none.
  Future<bool> resume();
}

/// Places played from, for the car's History tab.
abstract class CarHistoryStore {
  List<String> load();
  Future<void> save(List<String> entries);
}

/// The library as Android Auto and CarPlay show it: a short, driving-safe
/// menu over the media servers, with audio only.
///
/// Node ids carry everything needed to act on them, so a car can ask for a
/// node after a restart:
///
/// ```text
/// history, library          the tabs
/// c|<udn>|<container id>    a server folder (0 is a server's top)
/// t|<udn>|<parent>|<item>   a track; playing it plays its folder from it
/// a|<udn>|<object id>       a search result: an album plays whole
/// ```
class CarLibrary {
  /// The top level, which holds the tabs.
  static const top = '';
  static const history = 'history';
  static const library = 'library';

  /// Lists longer than this are cut short; the phone app and search are
  /// there for the rest. Android Auto asks for a whole list at once, so
  /// this is what it can reach, A–Z jump included.
  static const maxItems = 1000;
  static const _maxHistory = 12;

  final CarSource source;
  final CarPlayer player;
  final CarHistoryStore store;

  CarLibrary(this.source, this.player, this.store) {
    _servers = _serverIds();
    source.changes.listen((_) {
      final now = _serverIds();
      if (now == _servers) return;
      _servers = now;
      _changed.add(library);
    });
  }

  final _changed = StreamController<String>.broadcast();
  late String _servers;

  /// Ids whose children have changed, for the car to ask again: [top],
  /// [library] or [history].
  Stream<String> get changed => _changed.stream;

  String _serverIds() => [for (final s in source.servers) '${s.udn}|${s.name}|${s.via}'].join('\n');

  /// The top level: shown as tabs in Android Auto and CarPlay.
  List<CarNode> roots() => [
        if (store.load().isNotEmpty) const CarNode(history, 'Recent', browsable: true),
        const CarNode(library, 'Library', browsable: true),
      ];

  Future<List<CarNode>> children(String id, {int? page, int? pageSize}) async {
    if (id == history) return _history();
    if (id == library) {
      return [
        for (final s in source.servers)
          CarNode(_id(['c', s.udn, '0']), s.name, subtitle: s.via == null ? null : 'via ${s.via}', browsable: true),
      ];
    }
    final parts = _parts(id);
    if (parts.length != 3 || parts[0] != 'c') return const [];
    final udn = parts[1], containerId = parts[2];
    final start = page != null && pageSize != null ? page * pageSize : 0;
    final count = pageSize ?? maxItems;
    if (start >= maxItems) return const [];
    final objects = <DidlObject>[];
    while (objects.length < count) {
      final r = await source.browse(udn, containerId, start: start + objects.length, count: count - objects.length);
      objects.addAll(r.objects);
      if (r.objects.isEmpty || (r.totalMatches > 0 && start + objects.length >= r.totalMatches)) break;
    }
    return [for (final o in objects) ?_node(udn, containerId, o)];
  }

  /// Albums and tracks matching [query], from every server that can search.
  Future<List<CarNode>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final out = <CarNode>[];
    for (final s in source.servers) {
      final (albums, tracks) = await _search(s.udn, q);
      for (final a in albums) {
        out.add(CarNode(_id(['a', s.udn, a.id]), a.title,
            subtitle: a.performer ?? a.composer, art: a.albumArt, playable: true));
      }
      for (final t in tracks) {
        out.add(CarNode(_id(['a', s.udn, t.id]), t.title,
            subtitle: [t.performer, t.album].nonNulls.join(' · '), art: t.albumArt, playable: true));
      }
    }
    return out;
  }

  /// Plays what a node stands for.
  Future<void> play(String id) async {
    final parts = _parts(id);
    switch (parts) {
      case ['t', final udn, final parent, final item]:
        final tracks = await _audioChildren(udn, parent);
        final start = tracks.indexWhere((t) => t.id == item);
        if (tracks.isEmpty) return;
        await player.playItems(tracks, start < 0 ? 0 : start);
        await _remember(udn, parent, tracks.first);
      case ['c', final udn, final container]:
        final tracks = await source.tracks(udn, container);
        if (tracks.isEmpty) return;
        await player.playItems(tracks, 0);
        await _remember(udn, container, tracks.first);
      case ['a', final udn, final objectId]:
        // A search result: an album plays whole; a track plays alone.
        final tracks = await source.tracks(udn, objectId);
        if (tracks.isNotEmpty) {
          await player.playItems(tracks, 0);
          await _remember(udn, objectId, tracks.first);
        } else {
          final hit = _lastSearch[id];
          if (hit != null) await player.playItems([hit], 0);
        }
    }
  }

  /// Plays the best match for a spoken request: an album if one matches,
  /// otherwise the matching tracks. With nothing to go on, resumes.
  Future<void> playFromSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      await player.resume();
      return;
    }
    for (final s in source.servers) {
      final (albums, tracks) = await _search(s.udn, q);
      if (albums.isNotEmpty) return play(_id(['a', s.udn, albums.first.id]));
      if (tracks.isNotEmpty) {
        await player.playItems(tracks, 0);
        return;
      }
    }
  }

  /// Notes a folder the app played from, for the History tab.
  Future<void> remember(String udn, String containerId, String title, Uri? art) async {
    final entry = jsonEncode({'udn': udn, 'id': containerId, 'title': title, 'art': ?art?.toString()});
    final before = store.load();
    final list = [entry, ...before.where((e) => _key(e) != '$udn|$containerId')];
    await store.save(list.take(_maxHistory).toList());
    // The Recent tab appears with the first entry.
    if (before.isEmpty) _changed.add(top);
    _changed.add(history);
  }

  Future<void> _remember(String udn, String containerId, DidlItem first) async {
    // The folder's own title isn't at hand when playing a track; the album
    // is what a driver recognises anyway.
    await remember(udn, containerId, first.album ?? first.title, first.albumArt);
  }

  final _lastSearch = <String, DidlItem>{};

  Future<(List<DidlContainer>, List<DidlItem>)> _search(String udn, String q) async {
    final s = q.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    try {
      final albums = await source.search(udn,
          'upnp:class derivedfrom "object.container.album" and (dc:title contains "$s" or upnp:artist contains "$s")',
          count: 20);
      final tracks = await source.search(udn,
          'upnp:class derivedfrom "object.item.audioItem" and '
          '(dc:title contains "$s" or upnp:artist contains "$s" or upnp:album contains "$s")',
          count: 50);
      final found = tracks.objects.whereType<DidlItem>().where((i) => i.isAudio).toList();
      for (final t in found) {
        _lastSearch[_id(['a', udn, t.id])] = t;
      }
      return (albums.objects.whereType<DidlContainer>().where(_isAudioContainer).toList(), found);
    } on Object {
      // A server without search, or one that's unreachable.
      return (const <DidlContainer>[], const <DidlItem>[]);
    }
  }

  Future<List<DidlItem>> _audioChildren(String udn, String containerId) async {
    final items = <DidlItem>[];
    var start = 0;
    while (items.length < 1000) {
      final r = await source.browse(udn, containerId, start: start);
      items.addAll(r.objects.whereType<DidlItem>().where((i) => i.isAudio));
      start += r.objects.length;
      if (r.objects.isEmpty || (r.totalMatches > 0 && start >= r.totalMatches)) break;
    }
    return items;
  }

  List<CarNode> _history() => [
        for (final e in store.load())
          if (jsonDecode(e) case {'udn': final String udn, 'id': final String id, 'title': final String title} && final m)
            CarNode(_id(['c', udn, id]), title,
                art: m['art'] is String ? Uri.tryParse(m['art'] as String) : null, browsable: true),
      ];

  String? _key(String entry) {
    try {
      final m = jsonDecode(entry) as Map;
      return '${m['udn']}|${m['id']}';
    } on Object {
      return null;
    }
  }

  CarNode? _node(String udn, String parent, DidlObject o) => switch (o) {
        DidlContainer c when _isAudioContainer(c) => CarNode(_id(['c', udn, c.id]), c.title,
            subtitle: _credits(c), art: c.albumArt, browsable: true),
        DidlItem i when i.isAudio => CarNode(_id(['t', udn, parent, i.id]), i.title,
            subtitle: _credits(i), art: i.albumArt, playable: true),
        _ => null, // video, pictures, anything else
      };

  /// Folders meant for pictures or video stay out of the car.
  static bool _isAudioContainer(DidlContainer c) {
    final cls = c.upnpClass.toLowerCase();
    return !cls.contains('photo') && !cls.contains('video') && !cls.contains('picture') && !cls.contains('image');
  }

  static String? _credits(DidlObject o) {
    final parts = {o.composer, o.performer}.nonNulls.where((p) => p != o.title);
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _id(List<String> parts) => parts.map(Uri.encodeComponent).join('|');
  static List<String> _parts(String id) => id.split('|').map(Uri.decodeComponent).toList();
}
