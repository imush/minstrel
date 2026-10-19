import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/playback/keep_alive.dart';
import 'package:minstrel/widgets/cover_art.dart';

void main() {
  test('formatDuration', () {
    expect(formatDuration(const Duration(minutes: 4, seconds: 5)), '4:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(formatDuration(null), '');
  });

  test('keep-alive runs only while a handover is still to come', () {
    // SetNext renderer (holds one ahead), 5 tracks.
    expect(keepAliveNeeded(queueLength: 5, index: 0, tracksAhead: 1), isTrue);
    expect(keepAliveNeeded(queueLength: 5, index: 2, tracksAhead: 1), isTrue);
    expect(keepAliveNeeded(queueLength: 5, index: 3, tracksAhead: 1), isFalse,
        reason: 'renderer already has the last track');
    // No SetNext: needed until the last track starts.
    expect(keepAliveNeeded(queueLength: 5, index: 3, tracksAhead: 0), isTrue);
    expect(keepAliveNeeded(queueLength: 5, index: 4, tracksAhead: 0), isFalse);
    // Single track, or nothing playing.
    expect(keepAliveNeeded(queueLength: 1, index: 0, tracksAhead: 1), isFalse);
    expect(keepAliveNeeded(queueLength: 5, index: -1, tracksAhead: 1), isFalse);
  });
}
