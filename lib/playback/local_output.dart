import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:rxdart/rxdart.dart';

import 'output.dart';

/// Plays on this device with just_audio. The whole queue is handed to the
/// player as one playlist, which ExoPlayer and AVQueuePlayer play gaplessly.
class LocalOutput implements Output {
  final AudioPlayer _player = AudioPlayer();
  final _states = BehaviorSubject<OutputState>.seeded(OutputState.idle);
  late final StreamSubscription<void> _sub;

  LocalOutput() {
    _sub = Rx.combineLatest4(
      _player.playerStateStream,
      _player.positionStream,
      _player.durationStream,
      _player.currentIndexStream,
      (PlayerState ps, Duration pos, Duration? dur, int? idx) => OutputState(
        playing: ps.playing && ps.processingState != ProcessingState.completed,
        buffering: ps.processingState == ProcessingState.loading ||
            ps.processingState == ProcessingState.buffering,
        completed: ps.processingState == ProcessingState.completed,
        index: idx ?? -1,
        position: pos,
        duration: dur,
      ),
    ).listen(_states.add, onError: (Object e) {
      _states.add(OutputState(error: e.toString(), index: _states.value.index));
    });
  }

  @override
  String get id => 'local';
  @override
  String get name => 'This device';
  @override
  bool get isLocal => true;

  @override
  Future<List<ProtocolInfo>> sinks() async =>
      Platform.isAndroid ? LocalSinks.android : LocalSinks.apple;

  @override
  Stream<OutputState> get states => _states.stream;
  @override
  OutputState get state => _states.value;

  @override
  Future<void> load(List<QueueEntry> entries, int index,
      {Duration position = Duration.zero, bool play = true}) async {
    await _player.setAudioSources(
      [for (final e in entries) AudioSource.uri(e.resource.uri)],
      initialIndex: index,
      initialPosition: position,
      preload: false,
    );
    if (play) unawaited(_player.play());
  }

  /// The local player never survives an app restart.
  @override
  Future<List<QueueEntry>?> attach(List<QueueEntry> saved) async => null;

  @override
  Future<void> insert(int at, List<QueueEntry> entries) =>
      _player.insertAudioSources(at, [for (final e in entries) AudioSource.uri(e.resource.uri)]);
  @override
  Future<void> removeAt(int at) => _player.removeAudioSourceAt(at);
  @override
  Future<void> move(int from, int to) => _player.moveAudioSource(from, to);

  @override
  Future<void> play() async {
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero, index: 0);
    }
    unawaited(_player.play()); // completes only when playback pauses
  }

  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> clear() async {
    await _player.stop();
    await _player.clearAudioSources();
  }
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> skipTo(int index) => _player.seek(Duration.zero, index: index);

  Future<void> setVolume(double v) => _player.setVolume(v);

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    await _player.dispose();
    await _states.close();
  }
}
