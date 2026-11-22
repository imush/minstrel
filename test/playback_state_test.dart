import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minstrel/playback/audio_handler.dart';

void main() {
  final t0 = DateTime(2026, 11, 17, 20);
  PlaybackState state({
    bool playing = true,
    Duration position = const Duration(seconds: 30),
    DateTime? at,
    int? index = 6,
    AudioProcessingState processing = AudioProcessingState.ready,
    double speed = 1.0,
  }) =>
      PlaybackState(
        controls: [MediaControl.skipToPrevious, playing ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext],
        processingState: processing,
        playing: playing,
        updatePosition: position,
        updateTime: at ?? t0,
        queueIndex: index,
        speed: speed,
      );

  group('a head unit is not sent', () {
    // Each state sent makes a VW head unit redraw its queue, putting the
    // driver's scroll back: the player's own position ticks, several a
    // second, made the queue impossible to scroll.
    test('a position tick while playing', () {
      final sent = state();
      final tick = state(position: const Duration(seconds: 30, milliseconds: 200),
          at: t0.add(const Duration(milliseconds: 200)));
      expect(onlyTimePassed(sent, tick), isTrue);
    });

    test('minutes of ticks, still where the session carried it', () {
      final sent = state();
      final later = state(position: const Duration(minutes: 3, seconds: 30), at: t0.add(const Duration(minutes: 3)));
      expect(onlyTimePassed(sent, later), isTrue);
    });

    test('the same state again while paused', () {
      final sent = state(playing: false);
      expect(onlyTimePassed(sent, state(playing: false, at: t0.add(const Duration(seconds: 5)))), isTrue);
    });
  });

  group('while a track loads', () {
    // Reported at speed 0, so the car's clock stands still rather than
    // counting through the silence.
    final loading = state(processing: AudioProcessingState.buffering, position: Duration.zero, speed: 0);

    test('a wait with the position where it was is not sent again', () {
      final later = state(
          processing: AudioProcessingState.buffering,
          position: Duration.zero,
          speed: 0,
          at: t0.add(const Duration(seconds: 20)));
      expect(onlyTimePassed(loading, later), isTrue);
    });

    test('the track starting is sent', () {
      final started = state(position: Duration.zero, at: t0.add(const Duration(seconds: 20)));
      expect(onlyTimePassed(loading, started), isFalse);
    });
  });

  group('a head unit is sent', () {
    test('pause and play', () {
      expect(onlyTimePassed(state(), state(playing: false)), isFalse);
      expect(onlyTimePassed(state(playing: false), state()), isFalse);
    });

    test('the next track', () {
      expect(onlyTimePassed(state(), state(index: 7, position: Duration.zero)), isFalse);
    });

    test('buffering', () {
      expect(onlyTimePassed(state(), state(processing: AudioProcessingState.buffering)), isFalse);
    });

    test('a seek', () {
      final seek = state(position: const Duration(minutes: 2), at: t0.add(const Duration(milliseconds: 300)));
      expect(onlyTimePassed(state(), seek), isFalse);
    });

    test('a position that fell behind, as when a renderer stalls', () {
      final stalled = state(position: const Duration(seconds: 31), at: t0.add(const Duration(seconds: 5)));
      expect(onlyTimePassed(state(), stalled), isFalse);
    });

    test('a position that moved while paused', () {
      expect(onlyTimePassed(state(playing: false), state(playing: false, position: const Duration(seconds: 45))),
          isFalse);
    });
  });
}
