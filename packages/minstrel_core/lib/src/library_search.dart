import 'didl.dart';
import 'services.dart';
import 'soap.dart';

/// What a search of a whole library found, by kind.
class LibrarySearchResult {
  final List<DidlContainer> artists;
  final List<DidlContainer> albums;
  final List<DidlItem> tracks;

  const LibrarySearchResult({this.artists = const [], this.albums = const [], this.tracks = const []});

  static const empty = LibrarySearchResult();

  bool get isEmpty => artists.isEmpty && albums.isEmpty && tracks.isEmpty;
}

/// Searches a server's whole library with ContentDirectory Search, using
/// only the properties the server says it can search.
///
/// Servers differ in how much of the query language they get right.
/// MinimServer, for one, mixes up `(a or b) and c`, so each query is the one
/// shape that works widely: a class and a list of alternatives, for the
/// rarest word typed, plus pieces of it (see [searchPieces]). All the words
/// are then matched here, ignoring case and accents and allowing small
/// misspellings.
class LibrarySearch {
  final ContentDirectory _cd;
  Future<Set<String>>? _caps;

  LibrarySearch(this._cd);

  /// The properties the server can search; empty when it can't search.
  Future<Set<String>> capabilities() => _caps ??= _cd.searchCapabilities().then(parseSearchCapabilities,
      onError: (Object e) {
        _caps = null; // Try again next time; the server may have been out of reach.
        throw e;
      });

  Future<bool> get supported async {
    final caps = await capabilities();
    return caps.contains('*') || caps.contains('dc:title');
  }

  static const artistClass = 'object.container.person';
  static const albumClass = 'object.container.album';
  static const trackClass = 'object.item.audioItem';
  static const composer = 'upnp:artist[@role="Composer"]';

  Future<LibrarySearchResult> search(String query,
      {int maxArtists = 20, int maxAlbums = 50, int maxTracks = 200}) async {
    final words = searchWords(query);
    if (words.isEmpty) return LibrarySearchResult.empty;
    final caps = await capabilities();
    bool can(String p) => caps.contains('*') || caps.contains(p);
    if (!can('dc:title')) return LibrarySearchResult.empty;
    final folded = words.map(foldForSearch).toList();
    // Close matches (a letter or two off) only if every word matches somehow;
    // listed after exact ones.
    final closeness = Expando<int>();
    bool matches(DidlObject o) {
      final score = matchScore(folded, searchText(o));
      closeness[o] = score;
      return score != null;
    }

    // Exact matches, then close ones, each in the server's order.
    List<T> ranked<T extends DidlObject>(Iterable<T> found) {
      final list = found.toList();
      return [
        for (final o in list) if (closeness[o] == 0) o,
        for (final o in list) if (closeness[o]! > 0) o,
      ];
    }

    List<String> fields(List<String> wanted) => [for (final f in wanted) if (can(f)) f];
    final trackFields = fields(['dc:title', 'upnp:artist', composer, 'dc:creator', 'upnp:album']);
    final albumFields = fields(['dc:title', 'upnp:artist', composer, 'dc:creator']);
    final keys = await _rarest(words, trackFields);

    if (can('upnp:class')) {
      try {
        final [artists, albums, tracks] = await Future.wait([
          _queryAll(artistClass, ['dc:title'], keys, maxArtists),
          _queryAll(albumClass, albumFields, keys, maxAlbums),
          _queryAll(trackClass, trackFields, keys, maxTracks),
        ]);
        return LibrarySearchResult(
          artists: ranked(artists.whereType<DidlContainer>().where(matches)),
          albums: ranked(albums.whereType<DidlContainer>().where(matches)),
          tracks: ranked(tracks.whereType<DidlItem>().where((i) => i.isAudio && matches(i))),
        );
      } on UpnpActionException {
        // Most likely `derivedfrom` refused; try without classes below.
      }
    }
    // Without classes in the query, sort out the kinds here.
    final all = await _queryAll(null, trackFields, keys, maxTracks);
    return LibrarySearchResult(
      artists: ranked(all.whereType<DidlContainer>().where((c) => c.upnpClass.startsWith(artistClass) && matches(c))),
      albums: ranked(all.whereType<DidlContainer>().where((c) => c.upnpClass.startsWith(albumClass) && matches(c))),
      tracks: ranked(all.whereType<DidlItem>().where((i) => i.isAudio && matches(i))),
    );
  }

  /// What to ask the server for: the word with the fewest matches, with its
  /// pieces (see [searchPieces]), so the results the server sends (a limited
  /// number) include everything the other words also match. "haydn symphony
  /// 94" asks for "94", not the thousand symphonies. A misspelt word counts
  /// with its pieces, since the word itself matches nothing.
  Future<List<String>> _rarest(List<String> words, List<String> fields) async {
    final groups = [for (final w in words) [w, ...searchPieces(w)]];
    if (words.length == 1) return groups.single;
    try {
      Future<int> count(String w) => _cd.search('0', searchCriteria(w, fields), count: 1).then((r) => r.totalMatches);
      final counts = await Future.wait([
        for (final g in groups) Future.wait(g.map(count)).then((c) => c.fold<int>(0, (a, b) => a + b)),
      ]);
      var best = 0;
      for (var i = 1; i < words.length; i++) {
        // Servers that don't count report 0; prefer a real count.
        if (counts[i] > 0 && (counts[best] == 0 || counts[i] < counts[best])) best = i;
      }
      return groups[best];
    } on Object {
      return (groups.toList()..sort((a, b) => b.first.length - a.first.length)).first;
    }
  }

  /// Results for each of [words], in order, without repeats.
  Future<List<DidlObject>> _queryAll(String? upnpClass, List<String> fields, List<String> words, int count) async {
    final pages = await Future.wait([for (final w in words) _query(upnpClass, fields, w, count)]);
    final seen = <String>{};
    return [
      for (final page in pages)
        for (final o in page)
          if (seen.add(o.id)) o,
    ];
  }

  Future<List<DidlObject>> _query(String? upnpClass, List<String> fields, String word, int count) async {
    if (fields.isEmpty) return const [];
    final criteria = searchCriteria(word, fields, upnpClass: upnpClass);
    final r = await _cd.search('0', criteria, count: count);
    return r.objects;
  }
}

/// Parses a GetSearchCapabilities answer, such as
/// `dc:title,upnp:artist[@role="Composer"]`; `*` means every property.
Set<String> parseSearchCapabilities(String caps) {
  // Commas also appear inside role filters in principle, so split only
  // outside brackets.
  final out = <String>{};
  var depth = 0;
  var start = 0;
  for (var i = 0; i < caps.length; i++) {
    final c = caps[i];
    if (c == '[') depth++;
    if (c == ']') depth--;
    if (c == ',' && depth == 0) {
      out.add(caps.substring(start, i).trim());
      start = i + 1;
    }
  }
  out.add(caps.substring(start).trim());
  return out..remove('');
}

/// `upnp:class derivedfrom "<class>" and (f1 contains "w" or f2 contains "w")`.
String searchCriteria(String word, List<String> fields, {String? upnpClass}) {
  final w = word.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  final any = fields.map((f) => '$f contains "$w"').join(' or ');
  if (upnpClass == null) return fields.length == 1 ? any : '($any)';
  return 'upnp:class derivedfrom "$upnpClass" and ($any)';
}

/// Pieces of [word] to search for besides the word itself: its first and
/// last three letters, or two for words of five or six letters, so a typo
/// in the middle leaves at least one piece intact. Servers compare accents
/// exactly, so "dvorak" misses "Dvořák", and a misspelling finds nothing:
/// "dvo" finds Dvořák, "cherkasky" finds Cherkassky through "che" and
/// "sky", and "haidn" finds Haydn through "dn". The results are then matched
/// here, without accents and allowing a letter or two off (see
/// [matchScore]). Shorter words need nothing extra.
List<String> searchPieces(String word) {
  final r = word.runes.toList();
  if (r.length < 5) return const [];
  final k = r.length <= 6 ? 2 : 3;
  return {String.fromCharCodes(r.take(k)), String.fromCharCodes(r.skip(r.length - k))}.toList();
}

/// How well [text] matches all of [words] (both folded, see
/// [foldForSearch]): 0 when each word appears in it, plus 1 for each word
/// that only nearly matches one of its words; null when some word doesn't
/// match at all.
int? matchScore(List<String> words, String text) {
  var score = 0;
  List<String>? tokens;
  for (final w in words) {
    if (text.contains(w)) continue;
    final allowed = w.length >= 8 ? 2 : w.length >= 5 ? 1 : 0;
    if (allowed == 0) return null;
    tokens ??= text.split(RegExp(r'[^\p{L}\p{N}]+', unicode: true));
    if (!tokens.any((t) => (t.length - w.length).abs() <= allowed && editDistance(t, w, max: allowed) <= allowed)) {
      return null;
    }
    score++;
  }
  return score;
}

/// Letters added, dropped, changed or swapped to turn [a] into [b]; stops
/// counting past [max].
int editDistance(String a, String b, {int max = 1 << 30}) {
  final m = a.length, n = b.length;
  var prev2 = List<int>.filled(n + 1, 0);
  var prev = List<int>.generate(n + 1, (j) => j);
  for (var i = 1; i <= m; i++) {
    final cur = List<int>.filled(n + 1, 0)..[0] = i;
    var rowMin = i;
    for (var j = 1; j <= n; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var d = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost].reduce((x, y) => x < y ? x : y);
      if (i > 1 && j > 1 && a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) && a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
        d = d < prev2[j - 2] + 1 ? d : prev2[j - 2] + 1;
      }
      cur[j] = d;
      if (d < rowMin) rowMin = d;
    }
    if (rowMin > max) return max + 1;
    prev2 = prev;
    prev = cur;
  }
  return prev[n];
}

/// The words of a search, without empty ones.
List<String> searchWords(String query) => query.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

/// Everything a search word may match in [o], folded for comparison.
String searchText(DidlObject o) => foldForSearch([
      o.title,
      for (final a in o.artists) a.name,
      for (final c in o.creators) c.name,
      ?o.album,
    ].join(' '));

/// Lower case without accents, so "beyonce" finds "Beyoncé" and "dvorak"
/// finds "Dvořák".
String foldForSearch(String s) {
  final lower = s.toLowerCase();
  final out = StringBuffer();
  for (final r in lower.runes) {
    final c = String.fromCharCode(r);
    out.write(_folded[c] ?? c);
  }
  return out.toString();
}

const _accents = {
  'a': 'àáâãäåāăą',
  'c': 'çćčĉċ',
  'd': 'ďđ',
  'e': 'èéêëēĕėęě',
  'g': 'ğĝġģ',
  'i': 'ìíîïĩīĭįı',
  'l': 'ĺļľłŀ',
  'n': 'ñńņňŉ',
  'o': 'òóôõöøōŏő',
  'r': 'ŕŗř',
  's': 'śŝşšș',
  't': 'ţťŧț',
  'u': 'ùúûüũūŭůűų',
  'y': 'ýÿŷ',
  'z': 'źżž',
  'ae': 'æ',
  'oe': 'œ',
  'ss': 'ß',
};

final _folded = {
  for (final e in _accents.entries)
    for (final c in e.value.split('')) c: e.key,
};
