import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:minstrel_core/minstrel_core.dart';

import 'device_storage.dart';

const int gigabyte = 1024 * 1024 * 1024;

/// One track kept on this device.
class CacheEntry {
  /// What identifies the track at home: see [CacheStore.keyFor].
  final String key;

  /// File name inside the cache directory. Not derived from [key]: a key is
  /// a path of any depth, and file names are not.
  final String file;

  final int bytes;

  /// The copy held here, as a `<res>`. [DidlResource.uri] is the home URL it
  /// came from, which is both its identity and where to fetch it again; the
  /// bytes are in [file].
  final DidlResource resource;

  /// The item's own metadata, kept so the cache can be listed and shown with
  /// no home in reach.
  final String didl;

  /// Pinned entries are never evicted. They still count against the budget:
  /// a budget that pins could exceed would mean nothing.
  final bool pinned;

  final DateTime lastPlayed;

  const CacheEntry({
    required this.key,
    required this.file,
    required this.bytes,
    required this.resource,
    required this.didl,
    required this.lastPlayed,
    this.pinned = false,
  });

  CacheEntry copyWith({bool? pinned, DateTime? lastPlayed}) => CacheEntry(
        key: key,
        file: file,
        bytes: bytes,
        resource: resource,
        didl: didl,
        pinned: pinned ?? this.pinned,
        lastPlayed: lastPlayed ?? this.lastPlayed,
      );

  /// The item as it should be played from here, pointing at the local file.
  DidlItem get item {
    final parsed = parseDidlLite(didl).whereType<DidlItem>().firstOrNull;
    return parsed ?? (throw StateError('cached metadata for $key is not an item'));
  }

  Map<String, Object?> toJson() => {
        'key': key,
        'file': file,
        'bytes': bytes,
        'res': resourceToJson(resource),
        'didl': didl,
        if (pinned) 'pinned': true,
        'lastPlayed': lastPlayed.toIso8601String(),
      };

  static CacheEntry? fromJson(Map<String, Object?> j) {
    final key = j['key'] as String?;
    final file = j['file'] as String?;
    final didl = j['didl'] as String?;
    final res = resourceFromJson(j['res']);
    if (key == null || file == null || didl == null || res == null) return null;
    return CacheEntry(
      key: key,
      file: file,
      bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      resource: res,
      didl: didl,
      pinned: j['pinned'] == true,
      lastPlayed: DateTime.tryParse(j['lastPlayed'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

/// A `<res>` as JSON, shared by the cache index and the fetcher's queue.
Map<String, Object?> resourceToJson(DidlResource r) {
  final p = r.protocolInfo;
  return {
    'uri': r.uri.toString(),
    if (p != null) 'protocolInfo': '${p.protocol}:${p.network}:${p.contentFormat}:${p.additionalInfo}',
    if (r.duration != null) 'durationMs': r.duration!.inMilliseconds,
    if (r.size != null) 'size': r.size,
    if (r.bitrate != null) 'bitrate': r.bitrate,
    if (r.sampleFrequency != null) 'sampleFrequency': r.sampleFrequency,
    if (r.bitsPerSample != null) 'bitsPerSample': r.bitsPerSample,
    if (r.channels != null) 'channels': r.channels,
  };
}

DidlResource? resourceFromJson(Object? raw) {
  if (raw is! Map) return null;
  final j = raw.cast<String, Object?>();
  final uri = Uri.tryParse(j['uri'] as String? ?? '');
  if (uri == null) return null;
  final ms = (j['durationMs'] as num?)?.toInt();
  return DidlResource(
    uri: uri,
    protocolInfo: ProtocolInfo.parse(j['protocolInfo'] as String?),
    duration: ms == null ? null : Duration(milliseconds: ms),
    size: (j['size'] as num?)?.toInt(),
    bitrate: (j['bitrate'] as num?)?.toInt(),
    sampleFrequency: (j['sampleFrequency'] as num?)?.toInt(),
    bitsPerSample: (j['bitsPerSample'] as num?)?.toInt(),
    channels: (j['channels'] as num?)?.toInt(),
  );
}

/// Music kept on this device so it plays away from home, or when home can't
/// be reached.
///
/// A least-recently-played cache under a budget the owner sets, filled by
/// [CacheFetcher] from what has actually been played rather than by
/// intercepting playback: routing playback through the cache would make a
/// renderer at home depend on the phone staying put.
///
/// Two limits, which are not the same thing. The **budget** is the owner's,
/// and eviction serves it. The **device** being nearly full is a separate
/// brake that only ever stops new entries: a cache that deleted other
/// people's files to make room for itself would be worse than one that
/// stops and says so.
class CacheStore extends ChangeNotifier {
  /// Where the files live. In Application Support rather than a caches
  /// directory, which both platforms may empty under pressure — that would
  /// quietly throw away music somebody pinned on purpose.
  final Directory dir;

  /// Seam for tests, which have no device to measure.
  @visibleForTesting
  final Future<StorageSpace?> Function() space;

  /// How full the device has to be before nothing more is kept.
  static const brake = 0.95;

  /// Names in [dir] that are bookkeeping rather than cached music, and so
  /// are not swept away as strays.
  static const reserved = {'index.json', 'wanted.json'};

  CacheStore(this.dir, {Future<StorageSpace?> Function()? space})
      : space = space ?? DeviceStorage.space;

  final Map<String, CacheEntry> _entries = {};
  int _nextFile = 1;

  /// Whether to keep anything at all.
  ///
  /// Turning it off empties the cache, which is why the switch asks first:
  /// a feature that says off while holding several gigabytes would be
  /// lying, and freeing the space is usually the reason for turning it off.
  bool enabled = true;

  /// What the cache may hold, in bytes. Zero means nothing can be kept.
  int budget = 0;

  /// The budget to start with: a tenth of the free space, in whole
  /// gigabytes.
  ///
  /// Rounded down, so the default never overcommits a phone that is nearly
  /// full. Below a gigabyte it rounds to nothing, and a cache too small for
  /// an album is only good for producing warnings, so a gigabyte is the
  /// floor and less free space than that starts the feature off.
  static int defaultBudget(StorageSpace? space) {
    if (space == null) return gigabyte;
    if (space.free < gigabyte) return 0;
    final tenth = (space.free ~/ 10) ~/ gigabyte * gigabyte;
    return tenth < gigabyte ? gigabyte : tenth;
  }

  List<CacheEntry> get entries => _entries.values.toList()
    ..sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));

  /// What is held now, for the settings page to show beside the budget.
  int get bytes => _entries.values.fold(0, (n, e) => n + e.bytes);

  int get pinnedBytes =>
      _entries.values.where((e) => e.pinned).fold(0, (n, e) => n + e.bytes);

  /// Nothing more can be kept because pinned music fills the budget. Worth
  /// saying out loud: the cache looks broken otherwise.
  bool get pinnedFillBudget => enabled && budget > 0 && pinnedBytes >= budget;

  File fileOf(CacheEntry e) => File('${dir.path}/${e.file}');

  /// The entry held in [name], for the relay to serve by file name.
  ///
  /// Only names the cache itself minted match, so a name invented by
  /// whoever is on the network reaches nothing — there is no path here to
  /// traverse out of.
  CacheEntry? byFile(String name) {
    for (final e in _entries.values) {
      if (e.file == name) return e;
    }
    return null;
  }

  /// What identifies a track, whichever way it was reached.
  ///
  /// A home's server shows up twice: directly on the LAN when the phone is
  /// at home, and behind the launchpad as
  /// `/h/<home>/u/<host:port>/<path>` otherwise. Both end in the same
  /// `<host:port>/<path>`, so that tail is the identity and a track cached
  /// at home is still recognised from a hotel.
  ///
  /// Null for anything that isn't a server's own URL: a relay URL is
  /// somebody else fetching through us, and a file URL is our own copy.
  static String? keyFor(Uri uri) {
    if (HomeProxy.isRelayUrl(uri)) return null;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    if (HomeProxy.isHomeUrl(uri)) {
      final upstream = RegExp(r'^/h/[^/]+/u/(.+)$').firstMatch(uri.path);
      return upstream == null ? null : '${upstream.group(1)}$query';
    }
    if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
    return '${uri.authority}${uri.path}$query';
  }

  /// Room a batch of new tracks has: the budget less what pins hold, since
  /// pins are the only thing eviction cannot reclaim.
  ///
  /// Used before a download to say so up front, rather than let the last
  /// tracks of an album evict its first ones.
  int get roomForBatch => (budget - pinnedBytes).clamp(0, budget);

  /// The entry for [key], or null. A file that has gone missing — storage
  /// reclaimed by the system, a volume unmounted — is dropped here rather
  /// than reported as a hit, which keeps the index self-healing.
  CacheEntry? entry(String key) {
    final e = _entries[key];
    if (e == null) return null;
    if (!fileOf(e).existsSync()) {
      _entries.remove(key);
      _saveSoon();
      return null;
    }
    return e;
  }

  /// The copy to play instead of fetching from home, or null to fetch.
  ///
  /// Away from home a cached copy stands in when it is at least as good as
  /// the one home would have given, and whatever its quality when home
  /// can't be reached at all — something is better than silence. [sinks]
  /// is the output's formats: a cached FLAC beats the MP3 a renderer would
  /// have been sent on quality and is no use to it whatsoever.
  CacheEntry? standIn(
    String key,
    DidlResource wanted, {
    required bool homeReachable,
    List<ProtocolInfo>? sinks,
  }) {
    final e = entry(key);
    if (e == null) return null;
    if (sinks != null) {
      final p = e.resource.protocolInfo;
      if (p == null || !sinks.any(p.playableBy)) return null;
    }
    if (!homeReachable) return e;
    return e.resource.atLeast(wanted) ? e : null;
  }

  /// Moves [key] to the front of the queue for eviction purposes.
  void touch(String key) {
    final e = _entries[key];
    if (e == null) return;
    _entries[key] = e.copyWith(lastPlayed: DateTime.now());
    _saveSoon();
  }

  Future<void> setPinned(String key, bool pinned) async {
    final e = _entries[key];
    if (e == null || e.pinned == pinned) return;
    _entries[key] = e.copyWith(pinned: pinned);
    await _save();
    notifyListeners();
  }

  /// Whether [wanted] is worth fetching: not held already, or held in a
  /// copy this one would improve on.
  bool wants(String key, DidlResource wanted) {
    if (!enabled || budget <= 0) return false;
    final held = entry(key);
    return held == null || wanted.isBetterThan(held.resource);
  }

  /// Takes [tmp] into the cache, evicting as needed, and returns the entry.
  ///
  /// Null when it was refused — the cache is off, the device is nearly
  /// full, a copy at least as good is already held, or the budget cannot
  /// make room even by evicting everything it may. [tmp] is deleted either
  /// way: the caller has nowhere else to put it.
  Future<CacheEntry?> adopt(
    File tmp, {
    required String key,
    required DidlResource resource,
    required String didl,
  }) async {
    Future<CacheEntry?> refuse() async {
      await _delete(tmp);
      return null;
    }

    if (!enabled || budget <= 0) return refuse();
    if (!await hasRoomOnDevice) return refuse();
    final size = await tmp.length();
    if (size <= 0 || size > budget) return refuse();

    final held = entry(key);
    if (held != null && !resource.isBetterThan(held.resource)) return refuse();
    if (held != null) await _remove(held);

    if (!_evictFor(size)) return refuse();

    await dir.create(recursive: true);
    final name = '${_nextFile++}${_extensionFor(resource)}';
    try {
      await tmp.rename('${dir.path}/$name');
    } on FileSystemException {
      // Across devices rename fails; copy instead.
      await tmp.copy('${dir.path}/$name');
      await _delete(tmp);
    }
    final e = CacheEntry(
      key: key,
      file: name,
      bytes: size,
      resource: resource,
      didl: didl,
      lastPlayed: DateTime.now(),
    );
    _entries[key] = e;
    await _save();
    notifyListeners();
    return e;
  }

  /// Whether the device has room to spare. Unmeasurable counts as room: a
  /// platform that won't answer shouldn't disable the feature.
  Future<bool> get hasRoomOnDevice async {
    final s = await space();
    return s == null || s.full < brake;
  }

  /// Evicts least-recently-played unpinned entries until [size] more bytes
  /// fit. False when they never will.
  bool _evictFor(int size) {
    if (bytes + size <= budget) return true;
    final candidates = _entries.values.where((e) => !e.pinned).toList()
      ..sort((a, b) => a.lastPlayed.compareTo(b.lastPlayed));
    for (final e in candidates) {
      if (bytes + size <= budget) return true;
      _entries.remove(e.key);
      _delete(fileOf(e));
    }
    return bytes + size <= budget;
  }

  /// Brings the cache back under the budget, for when the owner lowers it.
  Future<void> trim() async {
    _evictFor(0);
    await _save();
    notifyListeners();
  }

  Future<void> remove(String key) async {
    final e = _entries[key];
    if (e == null) return;
    await _remove(e);
    await _save();
    notifyListeners();
  }

  /// Empties the cache, pins included: this is the owner saying so.
  Future<void> clear() async {
    for (final e in _entries.values.toList()) {
      await _delete(fileOf(e));
    }
    _entries.clear();
    await _save();
    notifyListeners();
  }

  Future<void> _remove(CacheEntry e) async {
    _entries.remove(e.key);
    await _delete(fileOf(e));
  }

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Already gone, or not ours to delete; the index no longer names it.
    }
  }

  static String _extensionFor(DidlResource r) {
    final name = r.uri.pathSegments.lastOrNull ?? '';
    final dot = name.lastIndexOf('.');
    if (dot > 0 && dot >= name.length - 5) return name.substring(dot);
    return switch (r.mimeType) {
      'audio/flac' => '.flac',
      'audio/mpeg' => '.mp3',
      'audio/mp4' => '.m4a',
      'audio/wav' => '.wav',
      'audio/aiff' => '.aiff',
      'audio/ogg' => '.ogg',
      _ => '.bin',
    };
  }

  File get _index => File('${dir.path}/index.json');

  Future<void> load() async {
    _entries.clear();
    try {
      final j = jsonDecode(await _index.readAsString()) as Map<String, Object?>;
      for (final row in (j['entries'] as List? ?? const [])) {
        final e = CacheEntry.fromJson((row as Map).cast<String, Object?>());
        if (e != null) _entries[e.key] = e;
      }
      _nextFile = (j['nextFile'] as num?)?.toInt() ?? 1;
    } on Object {
      // No index yet, or one we can't read. The files without it are
      // anonymous, so start over rather than leave them to accumulate.
      _nextFile = 1;
      await _forgetStrays();
    }
    notifyListeners();
  }

  /// Files the index doesn't name are unreachable and would never be
  /// evicted, so they go.
  Future<void> _forgetStrays() async {
    if (!await dir.exists()) return;
    final named = {for (final e in _entries.values) e.file, ...reserved};
    await for (final f in dir.list()) {
      if (f is File && !named.contains(f.uri.pathSegments.last)) await _delete(f);
    }
  }

  Future<void> _save() async {
    await dir.create(recursive: true);
    await _index.writeAsString(jsonEncode({
      'nextFile': _nextFile,
      'entries': [for (final e in _entries.values) e.toJson()],
    }));
  }

  /// For changes not worth an await, such as a play touching an entry.
  void _saveSoon() {
    _save().catchError((_) {});
  }
}
