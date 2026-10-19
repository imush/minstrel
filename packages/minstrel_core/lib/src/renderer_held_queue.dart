import 'dart:async';

import 'openhome.dart';
import 'queue_snapshot.dart';
import 'renderer_queue.dart';
import 'services.dart';

/// What a renderer reports when polled. Renderers identify the current
/// track either by playlist id (OpenHome) or by URI (AVTransport).
class PlaylistPoll {
  final TransportState state;
  final int? currentId;
  final String? currentUri;
  final Duration position;
  final Duration? duration;

  const PlaylistPoll(this.state, this.position, this.duration,
      {this.currentId, this.currentUri});
}

/// The protocol-specific part of a renderer-side playlist.
abstract interface class PlaylistBackend {
  /// Readies the device, e.g. switching an OpenHome product to its
  /// Playlist source.
  Future<void> prepare();
  Future<void> clear();

  /// Inserts after [afterId] (0 = at the start) and returns the new id.
  Future<int> insert(int afterId, QueueEntry entry);

  Future<void> remove(int id);

  /// The whole renderer-side playlist, in order.
  Future<List<PlaylistEntry>> readList();

  /// Starts playing the first track of a freshly loaded list.
  Future<void> start(int id);

  /// Moves from list position [from] to [to] (track id [toId]). Returns
  /// false if the backend can't do this cheaply, in which case the queue is
  /// reloaded from [to].
  Future<bool> jump(int from, int to, int toId);

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<PlaylistPoll> poll();
}

/// A queue held by the renderer itself. The renderer advances through the
/// tracks on its own, so playback continues while the phone sleeps, loses
/// Wi-Fi or is switched off. The phone only loads the list and follows
/// along.
///
/// The list is loaded from the requested start track onward (going back
/// before it reloads), and the first track starts playing before the rest
/// are inserted, so a long album starts as quickly as a single track.
class RendererHeldQueue implements RendererQueue {
  final PlaylistBackend backend;
  final Duration pollInterval;

  /// Upper bound on tracks sent to the renderer at once; many renderers cap
  /// their playlists at around 1000.
  final int maxLoaded;

  final _status = StreamController<RendererStatus>.broadcast();
  RendererStatus _last = RendererStatus.idle;

  List<QueueEntry> _queue = [];
  int _base = 0; // queue index of the renderer's first track
  final List<int> _ids = []; // renderer ids for _queue[_base...]
  int _index = -1;
  int _generation = 0; // bumped on reload, to stop stale inserts
  int _unknownPolls = 0;
  bool _polling = false;
  Timer? _timer;

  /// Playlist edits run one at a time, in order: each depends on the ids
  /// the previous one produced.
  Future<void> _tail = Future.value();

  RendererHeldQueue(this.backend,
      {this.pollInterval = const Duration(seconds: 1), this.maxLoaded = 1000});

  @override
  Stream<RendererStatus> get status => _status.stream;
  @override
  RendererStatus get current => _last;
  @override
  List<QueueEntry> get queue => List.unmodifiable(_queue);
  @override
  int get index => _index;
  @override
  bool get heldByRenderer => true;

  Future<T> _serial<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  int get _loadedEnd => _base + _ids.length;

  @override
  Future<void> playQueue(List<QueueEntry> entries, {int startIndex = 0}) {
    _generation++; // stop any fill in progress before queueing behind it
    return _serial(() async {
      _queue = List.of(entries);
      if (_queue.isEmpty) return backend.stop();
      await _load(startIndex.clamp(0, _queue.length - 1));
    });
  }

  @override
  Future<bool> attach(List<QueueEntry> saved) => _serial(() async {
        final list = await backend.readList();
        if (list.isEmpty) return false;
        final p = await backend.poll();
        final generation = ++_generation;

        final uris = [for (final e in list) normaliseUri(e.uri.toString())];
        final base = _findSlice(saved, uris);
        if (base >= 0) {
          _queue = List.of(saved);
          _base = base;
        } else {
          // Changed elsewhere since we saved it: the renderer's list wins.
          _queue = [for (final e in list) queueEntryFromMetadata(e.uri, e.metadata)];
          _base = 0;
        }
        _ids
          ..clear()
          ..addAll(list.map((e) => e.id));

        final at = p.currentId != null ? _ids.indexOf(p.currentId!) : _positionOfUri(p.currentUri);
        _index = _base + (at >= 0 ? at : 0);
        _unknownPolls = 0;
        _emit(RendererStatus(
            state: p.state, index: _index, position: p.position, duration: p.duration));
        _timer ??= Timer.periodic(pollInterval, (_) => _poll());
        // The saved queue may run past what the renderer was given.
        if (base >= 0) unawaited(_fill(generation));
        return true;
      });

  /// Where [uris] occur as a contiguous run in [saved], or -1.
  static int _findSlice(List<QueueEntry> saved, List<String> uris) {
    for (var k = 0; k + uris.length <= saved.length; k++) {
      var match = true;
      for (var j = 0; j < uris.length && match; j++) {
        match = normaliseUri(saved[k + j].resource.uri.toString()) == uris[j];
      }
      if (match) return k;
    }
    return -1;
  }

  Future<void> _load(int start) async {
    final generation = ++_generation;
    _base = start;
    _ids.clear();
    await backend.prepare();
    await backend.clear();
    final first = await backend.insert(0, _queue[start]);
    _ids.add(first);
    _index = start;
    await backend.start(first);
    _emit(RendererStatus(
        state: TransportState.transitioning,
        index: start,
        position: Duration.zero,
        duration: _queue[start].item.duration));
    _timer ??= Timer.periodic(pollInterval, (_) => _poll());
    unawaited(_fill(generation));
  }

  /// Inserts the remaining tracks behind the ones already loaded, one per
  /// turn so that edits made meanwhile slot in between.
  Future<void> _fill(int generation) async {
    try {
      while (await _serial(() async {
        if (generation != _generation) return false;
        final end = (_base + maxLoaded).clamp(0, _queue.length);
        if (_loadedEnd >= end) return false;
        _ids.add(await backend.insert(_ids.isEmpty ? 0 : _ids.last, _queue[_loadedEnd]));
        return true;
      })) {}
    } on Object {
      // The renderer refused a track or went away; it keeps what it has,
      // and skipping past the end reloads from there.
    }
  }

  @override
  Future<void> insert(int at, List<QueueEntry> entries) => _serial(() async {
        if (entries.isEmpty) return;
        at = at.clamp(0, _queue.length);
        final wasFullyLoaded = _loadedEnd >= _queue.length;
        _queue.insertAll(at, entries);
        if (_index >= 0 && at <= _index) _index += entries.length;
        if (at <= _base) {
          // Before the loaded part: kept by the phone, sent if skipped back to.
          _base += entries.length;
        } else if (at <= _loadedEnd && _ids.length < maxLoaded) {
          var after = _ids[at - _base - 1];
          var pos = at - _base;
          for (final e in entries) {
            after = await backend.insert(after, e);
            _ids.insert(pos++, after);
          }
        } else if (wasFullyLoaded) {
          unawaited(_fill(_generation));
        }
      });

  @override
  Future<void> removeAt(int at) => _serial(() async {
        if (at < 0 || at >= _queue.length) return;
        if (at >= _base && at < _loadedEnd) {
          await backend.remove(_ids.removeAt(at - _base));
        } else if (at < _base) {
          _base--;
        }
        _queue.removeAt(at);
        if (at < _index) _index--;
        // Removing the current track: the renderer moves on by itself, and
        // the next poll finds where.
      });

  @override
  Future<void> move(int from, int to) => _serial(() async {
        if (from == _index || from < 0 || from >= _queue.length) return;
        to = to.clamp(0, _queue.length - 1);
        final e = _queue[from];
        // Playlists have no move: delete and re-insert.
        if (from >= _base && from < _loadedEnd) {
          await backend.remove(_ids.removeAt(from - _base));
        } else if (from < _base) {
          _base--;
        }
        _queue.removeAt(from);
        if (from < _index) _index--;

        _queue.insert(to, e);
        if (to <= _index) _index++;
        if (to < _base || (to == _base && _index != _base)) {
          _base++;
        } else if (to <= _loadedEnd) {
          final pos = to - _base;
          final id = await backend.insert(pos == 0 ? 0 : _ids[pos - 1], e);
          _ids.insert(pos, id);
        }
      });

  @override
  Future<void> skipTo(int i) => _serial(() async {
        if (i < 0 || i >= _queue.length) return;
        final from = _index - _base;
        final to = i - _base;
        if (to >= 0 && to < _ids.length && from >= 0 && await backend.jump(from, to, _ids[to])) {
          _index = i;
          _emit(_last.copyWith(index: i, position: Duration.zero));
        } else {
          await _load(i);
        }
      });

  @override
  Future<void> next() => skipTo(_index + 1);

  @override
  Future<void> previous() async {
    if (_last.position > const Duration(seconds: 3) || _index <= 0) {
      await seek(Duration.zero);
    } else {
      await skipTo(_index - 1);
    }
  }

  @override
  Future<void> play() async {
    if (_index < 0) return;
    await backend.play();
    _timer ??= Timer.periodic(pollInterval, (_) => _poll());
  }

  @override
  Future<void> pause() => backend.pause();
  @override
  Future<void> stop() => backend.stop();
  @override
  Future<void> seek(Duration position) => backend.seek(position);

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final p = await backend.poll();
      final at = p.currentId != null ? _ids.indexOf(p.currentId!) : _positionOfUri(p.currentUri);
      if (at >= 0) {
        _index = _base + at;
        _unknownPolls = 0;
      } else if ((p.currentId ?? 0) != 0 || (p.currentUri ?? '').isNotEmpty) {
        _unknownPolls++;
      }
      final detached = _unknownPolls >= 3;
      _emit(RendererStatus(
        state: p.state,
        index: _index,
        position: p.position,
        duration: p.duration ?? (_index >= 0 ? _queue[_index].item.duration : null),
        detached: detached,
      ));
    } on Object {
      // Transient; try again next poll.
    } finally {
      _polling = false;
    }
  }

  int _positionOfUri(String? uri) {
    if (uri == null || uri.isEmpty) return -1;
    final target = normaliseUri(uri);
    for (var i = 0; i < _ids.length; i++) {
      if (normaliseUri(_queue[_base + i].resource.uri.toString()) == target) return i;
    }
    return -1;
  }

  void _emit(RendererStatus s) {
    _last = s;
    if (!_status.isClosed) _status.add(s);
  }

  @override
  Future<void> dispose() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    await _status.close();
  }
}

/// OpenHome Playlist: id-addressed, with its own transport and Time
/// service.
class OpenHomeBackend implements PlaylistBackend {
  final OhPlaylist playlist;
  final OhTime? time;
  final OhProduct? product;

  OpenHomeBackend(this.playlist, {this.time, this.product});

  @override
  Future<void> prepare() async {
    try {
      await product?.selectPlaylistSource();
    } on Object {
      // Single-source devices may not implement source selection.
    }
  }

  @override
  Future<void> clear() => playlist.deleteAll();
  @override
  Future<int> insert(int afterId, QueueEntry e) =>
      playlist.insert(afterId, e.resource.uri, e.item.toDidlLite());
  @override
  Future<void> remove(int id) => playlist.deleteId(id);
  @override
  Future<List<PlaylistEntry>> readList() => playlist.readAll();
  @override
  Future<void> start(int id) => playlist.seekId(id);
  @override
  Future<bool> jump(int from, int to, int toId) async {
    await playlist.seekId(toId);
    return true;
  }

  @override
  Future<void> play() => playlist.play();
  @override
  Future<void> pause() => playlist.pause();
  @override
  Future<void> stop() => playlist.stop();
  @override
  Future<void> seek(Duration position) => playlist.seekSecondAbsolute(position.inSeconds);

  @override
  Future<PlaylistPoll> poll() async {
    final state = switch (await playlist.transportState()) {
      'Playing' => TransportState.playing,
      'Paused' => TransportState.paused,
      'Stopped' => TransportState.stopped,
      'Buffering' => TransportState.transitioning,
      _ => TransportState.unknown,
    };
    final id = await playlist.id();
    final t = await time?.time();
    return PlaylistPoll(state, t?.position ?? Duration.zero,
        t == null || t.duration == Duration.zero ? null : t.duration,
        currentId: id);
  }
}

/// Cambridge StreamMagic: list held by PlaylistExtension, transport through
/// AVTransport. Tested on a CXNv2: Play from stopped starts at the first
/// list entry, Next/Previous step through the list, and the renderer
/// advances by itself. Seek(TRACK_NR) is unreliable, so jumps use
/// Next/Previous.
class PlaylistExtensionBackend implements PlaylistBackend {
  final PlaylistExtension list;
  final AVTransport transport;

  /// Beyond this many steps, reloading is quicker than stepping.
  static const maxSteps = 8;

  PlaylistExtensionBackend(this.list, this.transport);

  @override
  Future<void> prepare() async {
    try {
      await transport.stop();
    } on Object {
      // Already stopped (701) or idle.
    }
  }

  @override
  Future<void> clear() => list.deleteAll();
  @override
  Future<int> insert(int afterId, QueueEntry e) =>
      list.insert(afterId, e.resource.uri, e.item.toDidlLite());
  @override
  Future<void> remove(int id) => list.delete(id);
  @override
  Future<List<PlaylistEntry>> readList() => list.readAll();
  @override
  Future<void> start(int id) => transport.play();

  @override
  Future<bool> jump(int from, int to, int toId) async {
    final steps = to - from;
    if (steps == 0 || steps.abs() > maxSteps) return steps == 0;
    for (var i = 0; i < steps.abs(); i++) {
      await (steps > 0 ? transport.next() : transport.previous());
    }
    return true;
  }

  @override
  Future<void> play() => transport.play();
  @override
  Future<void> pause() => transport.pause();
  @override
  Future<void> stop() => transport.stop();
  @override
  Future<void> seek(Duration position) => transport.seek(position);

  @override
  Future<PlaylistPoll> poll() async {
    final state = await transport.transportState();
    final p = await transport.positionInfo();
    return PlaylistPoll(state, p.position ?? Duration.zero, p.duration, currentUri: p.trackUri);
  }
}

/// Renderers re-escape URLs inconsistently, so URIs are compared decoded.
String normaliseUri(String uri) {
  try {
    return Uri.decodeFull(uri.trim());
  } on ArgumentError {
    return uri.trim();
  }
}

