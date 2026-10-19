import 'package:minstrel_core/minstrel_core.dart';

/// Where audio is played: this device, or a renderer on the network.
/// The audio handler owns the queue; an output only plays what it's given.
abstract class Output {
  /// `local`, or the renderer's UDN.
  String get id;
  String get name;
  bool get isLocal;

  /// Formats this output accepts, for choosing among an item's resources.
  Future<List<ProtocolInfo>> sinks();

  Stream<OutputState> get states;
  OutputState get state;

  /// Replaces the queue and starts playing at [index].
  Future<void> load(List<QueueEntry> entries, int index, {Duration position = Duration.zero, bool play = true});

  /// Follows what the output is already playing without interrupting it,
  /// returning its queue, or null if there's nothing to follow. [saved] is
  /// the app's last saved queue, preferred where it matches.
  Future<List<QueueEntry>?> attach(List<QueueEntry> saved);

  /// Queue edits; positions are queue indices. [move] never moves the
  /// current track.
  Future<void> insert(int at, List<QueueEntry> entries);
  Future<void> removeAt(int at);
  Future<void> move(int from, int to);

  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// Stops and forgets the queue, leaving the output idle (index -1).
  Future<void> clear();
  Future<void> seek(Duration position);
  Future<void> skipTo(int index);

  Future<void> dispose();
}

class OutputState {
  final bool playing;
  final bool buffering;
  final bool completed;
  final int index;
  final Duration position;
  final Duration? duration;
  final String? error;

  const OutputState({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.index = -1,
    this.position = Duration.zero,
    this.duration,
    this.error,
  });

  static const idle = OutputState();
}
