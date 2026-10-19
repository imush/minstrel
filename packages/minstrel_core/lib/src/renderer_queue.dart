import 'dart:async';

import 'didl.dart';
import 'services.dart';

/// A queued track with the resource chosen for the current output.
class QueueEntry {
  final DidlItem item;
  final DidlResource resource;

  const QueueEntry(this.item, this.resource);
}

class RendererStatus {
  final TransportState state;
  final int index;
  final Duration position;
  final Duration? duration;

  /// The renderer is playing something this session didn't queue, because
  /// another control point took over.
  final bool detached;

  const RendererStatus({
    required this.state,
    required this.index,
    required this.position,
    required this.duration,
    this.detached = false,
  });

  static const idle = RendererStatus(
      state: TransportState.noMediaPresent,
      index: -1,
      position: Duration.zero,
      duration: null);
}

/// Plays a queue of tracks on a network renderer.
///
/// Implementations differ in who holds the queue. When the renderer holds it
/// (OpenHome, vendor playlist services) playback continues with the phone
/// asleep or gone; when the phone holds it (plain AVTransport) the phone
/// must stay awake to start each track after the next one.
abstract interface class RendererQueue {
  Stream<RendererStatus> get status;
  RendererStatus get current;
  List<QueueEntry> get queue;
  int get index;

  /// Whether the renderer itself holds the queue.
  bool get heldByRenderer;

  Future<void> playQueue(List<QueueEntry> entries, {int startIndex = 0});

  /// Follows whatever the renderer is already doing, without interrupting
  /// it: after an app restart, or when another app started playback.
  /// [saved] is the app's last saved queue for this renderer, which is used
  /// where it matches the renderer (it has fuller metadata). Returns false
  /// when there is nothing to follow.
  Future<bool> attach(List<QueueEntry> saved);

  /// Inserts [entries] so the first lands at queue position [at]
  /// (`queue.length` appends).
  Future<void> insert(int at, List<QueueEntry> entries);

  /// Removes the entry at [at]. Removing the current track moves on to the
  /// one after it.
  Future<void> removeAt(int at);

  /// Moves an entry other than the current track.
  Future<void> move(int from, int to);
  Future<void> skipTo(int index);
  Future<void> next();
  Future<void> previous();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

extension RendererStatusCopy on RendererStatus {
  RendererStatus copyWith({int? index, Duration? position, bool? detached}) =>
      RendererStatus(
        state: state,
        index: index ?? this.index,
        position: position ?? this.position,
        duration: duration,
        detached: detached ?? this.detached,
      );
}
