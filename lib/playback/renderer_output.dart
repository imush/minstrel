import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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

  RendererOutput(this.renderer) {
    unawaited(readVolume());
  }

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
    if (position > Duration.zero) await _seekOncePlaying(s, position);
    if (!play) await s.pause();
  }

  /// Renderers such as the CXNv2 refuse Seek until the track has started,
  /// so a queue moved over mid-track would start from the beginning.
  static Future<void> _seekOncePlaying(RendererQueue s, Duration position) async {
    try {
      if (s.current.state != TransportState.playing) {
        await s.status
            .firstWhere((st) => st.state == TransportState.playing)
            .timeout(const Duration(seconds: 10));
      }
      await s.seek(position);
    } on TimeoutException {
      // Never started; nothing to seek in.
    } on StateError {
      // Disposed while waiting.
    } on UpnpActionException {
      // Can't seek this track; it plays from the start.
    }
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

  /// The renderer's volume, 0 to 100; null until read, or if it has no
  /// volume control. The Now Playing slider and, on Android, the side
  /// buttons both change it. Not disposed with the output: listeners may
  /// still be detaching.
  final volume = ValueNotifier<int?>(null);
  int? _volumeToSend;
  bool _sendingVolume = false;

  Future<void> readVolume() async {
    try {
      final v = await renderer.volume();
      // A change being sent is newer than what the renderer reports.
      if (v != null && !_sendingVolume) volume.value = v.clamp(0, 100);
    } on Object {
      // No volume control; the slider stays hidden.
    }
  }

  /// Sets the volume. While one request is out, newer values replace each
  /// other, so a quick run of changes sends only the last.
  void setVolume(int v) {
    v = v.clamp(0, 100);
    if (v == volume.value) return;
    volume.value = v;
    _volumeToSend = v;
    if (!_sendingVolume) unawaited(_sendVolume());
  }

  Future<void> _sendVolume() async {
    _sendingVolume = true;
    try {
      while (_volumeToSend != null) {
        final v = _volumeToSend!;
        _volumeToSend = null;
        try {
          await renderer.setVolume(v);
        } on Object {
          // Unreachable for now; the next change tries again.
        }
      }
    } finally {
      _sendingVolume = false;
    }
  }

  /// One press of a volume button: a sixteenth of the slider, as for the
  /// phone's own volume, so steps follow the slider's curve.
  void stepVolume(int direction) {
    final v = volume.value;
    if (v == null) return;
    var next = sliderToVolume((volumeToSlider(v) + direction / 16).clamp(0, 1));
    // Near zero the curve is flat; still move.
    if (next == v) next = v + direction.sign;
    setVolume(next);
  }

  /// Amplifiers are usually loud enough at 10 to 30, so the slider follows
  /// a curve: 20 sits near its middle-left instead of a fifth of the way
  /// along, giving the usual levels most of its length.
  static double volumeToSlider(int volume) => math.sqrt(volume.clamp(0, 100) / 100);
  static int sliderToVolume(double slider) => (slider * slider * 100).round();

  @override
  Future<void> dispose() async {
    _tick?.cancel();
    await _sub?.cancel();
    await _session?.dispose();
    await _states.close();
  }
}
