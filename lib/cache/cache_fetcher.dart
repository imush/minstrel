import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:minstrel_core/minstrel_core.dart';

import 'cache_store.dart';

/// A track the cache would like to hold, remembered until there is a chance
/// to fetch it.
class WantedTrack {
  final String key;
  final DidlResource resource;
  final String didl;

  /// Asked for outright, rather than noted because it was played.
  ///
  /// Requested tracks go first and are fetched wherever the phone is: the
  /// point of asking is usually that you are about to lose the network.
  final bool requested;

  /// Pin it once it is held, if that was asked for at the same time.
  final bool pin;

  /// Failed attempts so far, so a track that cannot be fetched is given up
  /// on rather than retried for ever.
  final int attempts;

  const WantedTrack(
    this.key,
    this.resource,
    this.didl, {
    this.requested = false,
    this.pin = false,
    this.attempts = 0,
  });

  WantedTrack get tried => WantedTrack(key, resource, didl,
      requested: requested, pin: pin, attempts: attempts + 1);

  Map<String, Object?> toJson() => {
        'key': key,
        'res': resourceToJson(resource),
        'didl': didl,
        if (requested) 'requested': true,
        if (pin) 'pin': true,
        if (attempts > 0) 'attempts': attempts,
      };

  static WantedTrack? fromJson(Map<String, Object?> j) {
    final key = j['key'] as String?;
    final didl = j['didl'] as String?;
    final res = resourceFromJson(j['res']);
    if (key == null || didl == null || res == null) return null;
    return WantedTrack(key, res, didl,
        requested: j['requested'] == true,
        pin: j['pin'] == true,
        attempts: (j['attempts'] as num?)?.toInt() ?? 0);
  }
}

/// What became of one wish.
enum _Wish {
  /// Newly asked for.
  queued,

  /// Was already waiting to be fetched.
  waiting,

  /// Already on this device, at this quality or better.
  held,

  /// Nothing here this device could play, so nothing to keep.
  unplayable,
}

/// Fills the cache: with what has been played, and with what has been asked
/// for outright.
///
/// A separate fetch rather than keeping what playback goes past, because
/// playback does not run through this device's cache: a renderer at home
/// fetches from the server itself, so routing music through the phone to
/// catch a copy would make the speakers stop when the phone left the house.
///
/// Tracks noted from playing are fetched only over a connection nobody pays
/// for by the megabyte — at home, or from a server on this network. An
/// album is a few hundred megabytes, and nobody asked for it. Tracks asked
/// for outright are fetched wherever the phone is.
class CacheFetcher extends ChangeNotifier {
  final CacheStore store;
  final HomeProxy proxy;

  /// Seams for tests, which have no home and no network.
  @visibleForTesting
  final bool Function(Uri source)? onFreeConnection;
  @visibleForTesting
  final Future<bool> Function(Uri from, File into)? download;

  /// How many tracks to remember. A long enough tail to cover a trip's
  /// worth of listening; past that the oldest wish is not worth keeping.
  static const maxWanted = 300;

  /// Attempts before a track is given up on. A server that is off, or a
  /// track that has been deleted, should not be retried for ever.
  static const maxAttempts = 5;

  CacheFetcher(this.store, this.proxy, {this.onFreeConnection, this.download});

  final List<WantedTrack> _wanted = [];
  Future<void> _running = Future.value();
  Future<void> _saving = Future.value();
  String? _fetching;
  bool _closed = false;

  /// What is still waiting, newest wish first.
  List<WantedTrack> get wanted => List.unmodifiable(_wanted);

  /// Tracks asked for outright and not yet held, for showing progress.
  int get pendingRequests => _wanted.where((w) => w.requested).length;

  /// The track being fetched right now, if any.
  String? get fetching => _fetching;

  File get _queueFile => File('${store.dir.path}/wanted.json');

  /// Notes that [item] was played, so a copy is worth keeping.
  ///
  /// [resource] is the one playback chose, which decides the quality kept.
  void notePlayed(DidlItem item, DidlResource resource) {
    _want(item, resource, requested: false, pin: false);
  }

  /// Asks for [items] to be kept on this device, whether or not they are
  /// played, and says what became of each.
  ///
  /// Every track is looked at on its own, so a half-finished album tops
  /// itself up rather than being taken for done.
  ///
  /// [pin] keeps them from ever being evicted, and pins what is already
  /// held. Without it they age out like anything else, which for a trip is
  /// usually what is wanted: they are the newest thing in the cache and so
  /// the last to go.
  ({int queued, int waiting, int held, int unplayable}) request(
    Iterable<DidlItem> items, {
    bool pin = false,
  }) {
    var queued = 0;
    var waiting = 0;
    var held = 0;
    var unplayable = 0;
    for (final item in items) {
      final res = ResourceSelector.select(item, _localSinks);
      if (res == null) {
        unplayable++; // no format this device's player accepts
        continue;
      }
      switch (_want(item, res, requested: true, pin: pin)) {
        case _Wish.queued:
          queued++;
        case _Wish.waiting:
          waiting++;
        case _Wish.held:
          held++;
        case _Wish.unplayable:
          unplayable++;
      }
    }
    return (queued: queued, waiting: waiting, held: held, unplayable: unplayable);
  }

  /// What [items] would take up, and what the cache has room for, so a
  /// download that cannot fit can say so before it starts rather than
  /// evict its own first tracks with its last ones.
  ({int bytes, int unknown, int room}) estimate(Iterable<DidlItem> items) {
    var bytes = 0;
    var unknown = 0;
    for (final item in items) {
      final res = ResourceSelector.select(item, _localSinks);
      if (res == null) continue;
      final key = CacheStore.keyFor(res.uri);
      if (key == null || !store.wants(key, res)) continue; // already held
      if (res.size case final size? when size > 0) {
        bytes += size;
      } else {
        unknown++;
      }
    }
    return (bytes: bytes, unknown: unknown, room: store.roomForBatch);
  }

  _Wish _want(DidlItem item, DidlResource resource,
      {required bool requested, required bool pin}) {
    final key = CacheStore.keyFor(resource.uri);
    if (key == null) return _Wish.unplayable; // a relay URL, or our own copy
    if (!store.wants(key, resource)) {
      // Already held at this quality or better; pin it if that was asked.
      if (pin) unawaited(store.setPinned(key, true));
      return _Wish.held;
    }
    final had = _wanted.indexWhere((w) => w.key == key);
    // An outright request outranks a note that it was played, and keeping
    // a pin already asked for matters more than the new wish not having it.
    final keepPin = pin || (had >= 0 && _wanted[had].pin);
    final keepRequested = requested || (had >= 0 && _wanted[had].requested);
    if (had >= 0) _wanted.removeAt(had);
    _wanted.insert(
        0, WantedTrack(key, resource, item.toDidlLite(), requested: keepRequested, pin: keepPin));
    if (_wanted.length > maxWanted) _wanted.removeRange(maxWanted, _wanted.length);
    unawaited(_saveQueue());
    notifyListeners();
    unawaited(pump());
    // Asking again for something still waiting has changed nothing worth
    // telling anybody about.
    return had >= 0 ? _Wish.waiting : _Wish.queued;
  }

  static List<ProtocolInfo> get _localSinks =>
      Platform.isAndroid ? LocalSinks.android : LocalSinks.apple;

  /// Fetches what is wanted, one track at a time.
  Future<void> pump() =>
      _running = _running.then((_) => _drain()).catchError((_) {});

  Future<void> _drain() async {
    while (!_closed && _wanted.isNotEmpty) {
      if (!store.enabled || store.budget <= 0) return;
      if (!await store.hasRoomOnDevice) return;
      final at = _nextIndex();
      if (at < 0) return; // nothing eligible here; wait for a better network
      final want = _wanted.removeAt(at);
      _fetching = want.key;
      notifyListeners();
      final held = !store.wants(want.key, want.resource) || await _fetch(want);
      _fetching = null;
      if (!held && want.attempts + 1 < maxAttempts) {
        _wanted.add(want.tried); // to the back, to try again later
      }
      await _saveQueue();
      notifyListeners();
    }
  }

  /// What to fetch next: anything asked for outright, then whatever was
  /// played that this network is the right one to fetch over.
  int _nextIndex() {
    for (var i = 0; i < _wanted.length; i++) {
      if (_wanted[i].requested) return i;
    }
    for (var i = 0; i < _wanted.length; i++) {
      if (_isFree(_wanted[i].resource.uri)) return i;
    }
    return -1;
  }

  Future<bool> _fetch(WantedTrack want) async {
    final tmp = File('${store.dir.path}/fetching-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await store.dir.create(recursive: true);
      // A saved URL may name a proxy port from an earlier run.
      final from = proxy.rehome(want.resource.uri);
      if (!await (download ?? _httpDownload)(from, tmp)) {
        await _discard(tmp);
        return false;
      }
      final kept = await store.adopt(tmp,
          key: want.key, resource: want.resource, didl: want.didl);
      if (kept == null) return false;
      if (want.pin) await store.setPinned(want.key, true);
      return true;
    } on Object {
      await _discard(tmp);
      return false;
    }
  }

  /// A whole file or nothing: a part of a track would later look like a hit
  /// and play as a track that stops halfway.
  static Future<bool> _httpDownload(Uri from, File into) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final res = await client.getUrl(from).then((r) => r.close());
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        return false;
      }
      final expected = res.contentLength;
      final sink = into.openWrite();
      try {
        await res.pipe(sink); // closes the sink, even on error
      } on Object {
        return false;
      }
      final written = await into.length();
      return written > 0 && (expected < 0 || written == expected);
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Whether fetching [uri] costs nobody anything: a server on this network,
  /// or a home reached over its own network rather than from outside.
  bool _isFree(Uri uri) {
    final override = onFreeConnection;
    if (override != null) return override(uri);
    if (HomeProxy.isHomeUrl(uri)) {
      final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (seg.length < 2) return false;
      final status = proxy.status(seg[1]);
      return status.state == HomeState.connected && status.atHome;
    }
    return true; // a server named directly is one on this network
  }

  static Future<void> _discard(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Nothing to clean up.
    }
  }

  Future<void> load() async {
    _wanted.clear();
    try {
      final rows = jsonDecode(await _queueFile.readAsString()) as List;
      for (final row in rows) {
        final w = WantedTrack.fromJson((row as Map).cast<String, Object?>());
        if (w != null) _wanted.add(w);
      }
    } on Object {
      // No queue yet, or one we can't read; the next play rebuilds it.
    }
    // Part-fetched files from a run that was killed mid-download.
    await _sweepPartials();
    notifyListeners();
  }

  Future<void> _sweepPartials() async {
    if (!await store.dir.exists()) return;
    await for (final f in store.dir.list()) {
      if (f is File && f.uri.pathSegments.last.startsWith('fetching-')) {
        await _discard(f);
      }
    }
  }

  /// Waits for the queue file to be written, for tests and for shutdown.
  @visibleForTesting
  Future<void> get saved => _saving;

  /// Writes the queue, serialised so two notes in quick succession cannot
  /// interleave into a half-written file.
  Future<void> _saveQueue() {
    final rows = [for (final w in _wanted) w.toJson()];
    return _saving = _saving.then((_) async {
      try {
        await store.dir.create(recursive: true);
        await _queueFile.writeAsString(jsonEncode(rows));
      } on Object {
        // The queue is a convenience; losing it costs a re-fetch.
      }
    });
  }

  /// Forgets everything still wanted, for when the cache is turned off.
  Future<void> forget() async {
    _wanted.clear();
    await _discard(_queueFile);
    notifyListeners();
  }

  void close() => _closed = true;
}
