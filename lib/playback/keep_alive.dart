import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// Whether the app must stay awake: the renderer doesn't yet hold every
/// remaining track, so at least one handover is still to come.
/// [tracksAhead] is how many tracks after the current one the renderer has.
bool keepAliveNeeded({required int queueLength, required int index, required int tracksAhead}) =>
    index >= 0 && queueLength - 1 - index > tracksAhead;

/// Keeps the app running on iOS while it drives a renderer that can't hold
/// the queue itself.
///
/// iOS suspends background apps that aren't playing audio, and a suspended
/// app can't hand the renderer its next track. Looping silence keeps the
/// app running. It mixes with other apps' audio, so it never stops or ducks
/// a podcast or navigation prompt, and it runs only while a queue is
/// playing: [linger] covers the gap between tracks, not pauses.
class KeepAlive {
  static const linger = Duration(seconds: 20);

  AudioPlayer? _player;
  Timer? _stopTimer;

  bool get running => _player != null;

  /// [needed]: a phone-held renderer queue is active. [playing]: it's
  /// currently playing (or buffering).
  void update({required bool needed, required bool playing}) {
    if (!needed) {
      _stop();
    } else if (playing) {
      _stopTimer?.cancel();
      _stopTimer = null;
      if (!running) unawaited(_start());
    } else if (running) {
      _stopTimer ??= Timer(linger, _stop);
    }
  }

  Future<void> _start() async {
    final p = _player = AudioPlayer();
    try {
      await _setMixing(true);
      await p.setLoopMode(LoopMode.one);
      await p.setAudioSource(AudioSource.asset('assets/silence.wav'));
      unawaited(p.play());
    } on Object {
      // Without it, the queue still catches up when the app is reopened.
      _stop();
    }
  }

  void _stop() {
    _stopTimer?.cancel();
    _stopTimer = null;
    final p = _player;
    _player = null;
    if (p == null) return;
    p.dispose();
    unawaited(_setMixing(false));
  }

  /// Switches the shared audio session between mixable (for the silent
  /// loop) and the normal music session used for local playback.
  static Future<void> _setMixing(bool mix) async {
    final session = await AudioSession.instance;
    await session.configure(mix
        ? const AudioSessionConfiguration.music().copyWith(
            avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers)
        : const AudioSessionConfiguration.music());
  }
}
