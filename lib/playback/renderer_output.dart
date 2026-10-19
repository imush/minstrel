import 'dart:async';

import 'package:minstrel_core/minstrel_core.dart';
import 'package:rxdart/rxdart.dart';

import 'output.dart';

/// Plays on a UPnP AV renderer. Between the renderer's one-second status
/// polls the position is extrapolated so progress bars move smoothly.
class RendererOutput implements Output {
  final MediaRenderer renderer;
  RendererQueue? _session;
  StreamSubscription<RendererStatus>? _sub;
  final _states = BehaviorSubject<OutputState>.seeded(OutputState.idle);
  Timer? _tick;
  DateTime _statusAt = DateTime.now();

  RendererOutput(this.renderer);

  @override
  String get id => renderer.udn;
  @override
  String get name => renderer.name;
  @override
  bool get isLocal => false;

  @override
  Future<List<ProtocolInfo>> sinks() async {
    final s = await renderer.sinks();
    // A renderer that doesn't report formats almost always takes these.
    return s.isNotEmpty
        ? s
        : ProtocolInfo.parseList('http-get:*:audio/mpeg:*,http-get:*:audio/flac:*');
  }

  @override
  Stream<OutputState> get states => _states.stream;
  @override
  OutputState get state => _states.value;

  /// Whether the renderer keeps playing the queue without the phone.
  bool get holdsQueue => renderer.holdsQueue;

  /// How many tracks the renderer has been given beyond the current one:
  /// all of them when it holds the queue, one with SetNext, else none.
  int get tracksAhead => switch (_session) {
        null => 0,
        AvTransportQueue q => q.supportsSetNext ? 1 : 0,
        final q => q.queue.length,
      };

  Future<RendererQueue> _ensureSession() async {
    if (_session != null) return _session!;
    final s = await renderer.createQueue();
    _sub = s.status.listen(_onStatus);
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _extrapolate());
    return _session = s;
  }

  void _onStatus(RendererStatus s) {
    _statusAt = DateTime.now();
    final queueLength = _session?.queue.length ?? 0;
    _states.add(OutputState(
      playing: s.state == TransportState.playing,
      buffering: s.state == TransportState.transitioning,
      completed: s.state == TransportState.stopped && s.index == queueLength - 1,
      index: s.detached ? -1 : s.index,
      position: s.position,
      duration: s.duration,
      error: s.detached ? 'Another app is controlling ${renderer.name}' : null,
    ));
  }

  void _extrapolate() {
    final s = _states.value;
    if (!s.playing) return;
    final elapsed = DateTime.now().difference(_statusAt);
    if (elapsed > const Duration(seconds: 3)) return; // stale; wait for poll
    final p = _session!.current.position + elapsed;
    final capped = s.duration != null && p > s.duration! ? s.duration! : p;
    _states.add(OutputState(
      playing: s.playing,
      buffering: s.buffering,
      index: s.index,
      position: capped,
      duration: s.duration,
      error: s.error,
    ));
  }

  @override
  Future<void> load(List<QueueEntry> entries, int index,
      {Duration position = Duration.zero, bool play = true}) async {
    final s = await _ensureSession();
    await s.playQueue(entries, startIndex: index);
    if (position > Duration.zero) {
      try {
        await s.seek(position);
      } on UpnpActionException {
        // Some renderers can't seek until playback has started; skip it.
      }
    }
    if (!play) await s.pause();
  }

  @override
  Future<List<QueueEntry>?> attach(List<QueueEntry> saved) async {
    final s = await _ensureSession();
    return await s.attach(saved) ? s.queue : null;
  }

  @override
  Future<void> insert(int at, List<QueueEntry> entries) async => _session?.insert(at, entries);
  @override
  Future<void> removeAt(int at) async => _session?.removeAt(at);
  @override
  Future<void> move(int from, int to) async => _session?.move(from, to);

  @override
  Future<void> play() async => (await _ensureSession()).play();
  @override
  Future<void> pause() async => _session?.pause();
  @override
  Future<void> stop() async => _session?.stop();
  @override
  Future<void> clear() async {
    final s = _session;
    _session = null;
    _tick?.cancel();
    _tick = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await s?.stop();
    } finally {
      await s?.dispose();
      _states.add(OutputState.idle);
    }
  }
  @override
  Future<void> seek(Duration position) async => _session?.seek(position);
  @override
  Future<void> skipTo(int index) async => _session?.skipTo(index);

  Future<int?> volume() => renderer.volume();
  Future<void> setVolume(int v) => renderer.setVolume(v);

  @override
  Future<void> dispose() async {
    _tick?.cancel();
    await _sub?.cancel();
    await _session?.dispose();
    await _states.close();
  }
}
