import 'dart:async';

import 'protocol_info.dart';
import 'services.dart';
import 'renderer_held_queue.dart' show normaliseUri;
import 'renderer_queue.dart';
import 'soap.dart';

/// Plays a queue on an AVTransport renderer.
///
/// The control point owns the queue; the renderer only ever holds the
/// current track and, when it supports SetNextAVTransportURI, the next one,
/// so that it can move between them without a gap. Without SetNext the
/// session starts each track itself when the previous one stops, which
/// leaves a short gap.
///
/// State is polled rather than evented, which keeps the phone from having
/// to accept incoming connections.
class AvTransportQueue implements RendererQueue {
  final AVTransport transport;
  final RenderingControl? renderingControl;
  final List<ProtocolInfo> sinks;
  final bool supportsSetNext;
  final Duration pollInterval;

  final _status = StreamController<RendererStatus>.broadcast();
  RendererStatus _last = RendererStatus.idle;

  List<QueueEntry> _queue = [];
  int _index = -1;
  int? _nextQueued; // index sent with SetNextAVTransportURI
  bool _userStopped = true;
  bool _busy = false; // a track change is in progress; ignore STOPPED
  bool _sawPlaying = false; // STOPPED only means 'ended' after PLAYING
  int _unknownUriPolls = 0;
  Timer? _timer;

  AvTransportQueue({
    required this.transport,
    required this.sinks,
    required this.supportsSetNext,
    this.renderingControl,
    this.pollInterval = const Duration(seconds: 1),
  });

  @override
  Stream<RendererStatus> get status => _status.stream;
  @override
  RendererStatus get current => _last;
  @override
  List<QueueEntry> get queue => List.unmodifiable(_queue);
  @override
  bool get heldByRenderer => false;
  @override
  int get index => _index;

  @override
  Future<void> playQueue(List<QueueEntry> entries, {int startIndex = 0}) async {
    _queue = List.of(entries);
    if (_queue.isEmpty) return stop();
    await _startAt(startIndex.clamp(0, _queue.length - 1));
  }

  /// The renderer only knows its current (and next) track, so this can only
  /// follow a saved queue that contains what it's playing.
  @override
  Future<bool> attach(List<QueueEntry> saved) async {
    final state = await transport.transportState();
    final pos = await transport.positionInfo();
    final uri = pos.trackUri;
    if (uri == null || uri.isEmpty) return false;
    final target = normaliseUri(uri);
    final i = saved.indexWhere((e) => normaliseUri(e.resource.uri.toString()) == target);
    if (i < 0) return false;

    _queue = List.of(saved);
    _index = i;
    final active = state == TransportState.playing ||
        state == TransportState.paused ||
        state == TransportState.transitioning;
    _userStopped = !active;
    _sawPlaying = state == TransportState.playing;
    _unknownUriPolls = 0;
    _nextQueued = null;
    if (active) await _queueNext();
    _emit(RendererStatus(
        state: state,
        index: i,
        position: pos.position ?? Duration.zero,
        duration: pos.duration ?? saved[i].item.duration));
    _ensurePolling();
    return true;
  }

  @override
  Future<void> insert(int at, List<QueueEntry> entries) async {
    if (entries.isEmpty) return;
    at = at.clamp(0, _queue.length);
    _queue.insertAll(at, entries);
    if (_index >= 0 && at <= _index) _index += entries.length;
    if (at == _index + 1) await _requeueNext();
  }

  @override
  Future<void> removeAt(int at) async {
    if (at < 0 || at >= _queue.length) return;
    _queue.removeAt(at);
    if (at < _index) {
      _index--;
    } else if (at == _index) {
      if (at < _queue.length && !_userStopped) {
        await _startAt(at);
      } else {
        _index = at < _queue.length ? at : _queue.length - 1;
        if (at >= _queue.length) await stop();
        _nextQueued = null;
      }
    } else if (at == _index + 1) {
      await _requeueNext();
    }
  }

  @override
  Future<void> move(int from, int to) async {
    if (from == _index || from < 0 || from >= _queue.length) return;
    to = to.clamp(0, _queue.length - 1);
    final nextBefore = _index + 1 < _queue.length ? _queue[_index + 1] : null;
    final e = _queue.removeAt(from);
    if (from < _index) _index--;
    _queue.insert(to, e);
    if (to <= _index) _index++;
    final nextAfter = _index + 1 < _queue.length ? _queue[_index + 1] : null;
    if (!identical(nextBefore, nextAfter)) await _requeueNext();
  }

  /// The track after the current one changed; tell the renderer.
  Future<void> _requeueNext() async {
    _nextQueued = null;
    if (_index >= 0) await _queueNext();
  }

  @override
  Future<void> skipTo(int i) async {
    if (i < 0 || i >= _queue.length) return;
    await _startAt(i);
  }

  @override
  Future<void> next() => skipTo(_index + 1);

  @override
  Future<void> previous() async {
    // Restart the current track unless near its start, as most players do.
    if (_last.position > const Duration(seconds: 3) || _index <= 0) {
      await seek(Duration.zero);
    } else {
      await skipTo(_index - 1);
    }
  }

  @override
  Future<void> play() async {
    _userStopped = false;
    if (_last.state == TransportState.stopped && _index >= 0) {
      await _startAt(_index);
    } else {
      await transport.play();
    }
    _ensurePolling();
  }

  @override
  Future<void> pause() => transport.pause();

  @override
  Future<void> stop() async {
    _userStopped = true;
    await transport.stop();
  }

  @override
  Future<void> seek(Duration position) => transport.seek(position);

  Future<void> _startAt(int i) async {
    _busy = true;
    _userStopped = false;
    try {
      _index = i;
      _nextQueued = null;
      _sawPlaying = false;
      final e = _queue[i];
      await transport.setUri(e.resource.uri, e.item.toDidlLite());
      await transport.play();
      _emit(_last.copyWith(index: i, position: Duration.zero, detached: false));
      await _queueNext();
    } finally {
      _busy = false;
    }
    _ensurePolling();
  }

  Future<void> _queueNext() async {
    if (!supportsSetNext) return;
    final n = _index + 1;
    if (_nextQueued == n) return;
    try {
      if (n < _queue.length) {
        final e = _queue[n];
        await transport.setNextUri(e.resource.uri, e.item.toDidlLite());
      } else if (_nextQueued != null) {
        await transport.setNextUri(null, '');
      }
      _nextQueued = n < _queue.length ? n : null;
    } on UpnpActionException {
      // Some renderers reject SetNext while transitioning; retry next poll.
    }
  }

  void _ensurePolling() {
    _timer ??= Timer.periodic(pollInterval, (_) => _poll());
  }

  bool _polling = false;

  Future<void> _poll() async {
    if (_polling || _busy) return;
    _polling = true;
    try {
      final state = await transport.transportState();
      final pos = await transport.positionInfo();

      // Did the renderer move on to the track we queued with SetNext?
      final at = _indexOfUri(pos.trackUri);
      if (at != null && at != _index) {
        _index = at;
        _nextQueued = null;
        _unknownUriPolls = 0;
        unawaited(_queueNext());
      } else if (at == null && pos.trackUri != null && pos.trackUri!.isNotEmpty) {
        // Allow a couple of polls for renderers that report the URI late.
        _unknownUriPolls++;
      } else {
        _unknownUriPolls = 0;
      }
      final detached = _unknownUriPolls >= 3;
      if (state == TransportState.playing) _sawPlaying = true;

      _emit(RendererStatus(
        state: state,
        index: _index,
        position: pos.position ?? Duration.zero,
        duration: pos.duration ?? _currentEntry?.item.duration,
        detached: detached,
      ));

      if (detached) return;

      // Without SetNext, or if the renderer ignored it, advance ourselves.
      if (state == TransportState.stopped && !_userStopped && _sawPlaying) {
        if (_index + 1 < _queue.length) {
          await _startAt(_index + 1);
        } else {
          _userStopped = true; // end of queue
        }
      }
    } on Object {
      // Network hiccup or renderer busy; the next poll will retry.
    } finally {
      _polling = false;
    }
  }

  QueueEntry? get _currentEntry =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;

  int? _indexOfUri(String? uri) {
    if (uri == null || uri.isEmpty) return null;
    final target = normaliseUri(uri);
    // Check the expected positions first; queues may repeat a track.
    for (final i in [_index, _index + 1]) {
      if (i >= 0 && i < _queue.length && normaliseUri(_queue[i].resource.uri.toString()) == target) {
        return i;
      }
    }
    for (var i = 0; i < _queue.length; i++) {
      if (normaliseUri(_queue[i].resource.uri.toString()) == target) return i;
    }
    return null;
  }

  void _emit(RendererStatus s) {
    _last = s;
    if (!_status.isClosed) _status.add(s);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _status.close();
  }
}
