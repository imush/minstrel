import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Keeps Minstrel the phone's audio app on iOS while a renderer plays.
///
/// iOS shows lock screen and Control Center controls only for the app
/// playing audio, and suspends background apps that aren't. Casting plays
/// nothing on the phone, so without this the lock screen has no controls,
/// and a suspended app can't hand the renderer its next track. Looping
/// silence in the normal music session fixes both. Like any music app it
/// stops other apps' audio when casting starts; an app that then takes the
/// audio back takes the lock screen too, and the renderer plays on.
///
/// The silence plays while the renderer does and pauses when it pauses, so
/// the lock screen keeps the controls to resume it.
class KeepAlive {
  AudioPlayer? _player;

  /// What the renderer was last doing. The silence follows its changes
  /// only, so after another app interrupts it, it doesn't take the audio
  /// back until the renderer is paused and played again.
  bool _playing = false;

  bool get running => _player != null;

  /// [active]: a renderer queue is loaded. [playing]: it's playing (or
  /// buffering).
  void update({required bool active, required bool playing}) {
    if (!active) {
      _stop();
    } else if (!running) {
      _playing = playing;
      unawaited(_start(playing));
    } else if (playing != _playing) {
      _playing = playing;
      unawaited(playing ? _player!.play() : _player!.pause());
    }
  }

  Future<void> _start(bool playing) async {
    final p = _player = AudioPlayer();
    try {
      await p.setLoopMode(LoopMode.one);
      await p.setAudioSource(AudioSource.asset('assets/silence.wav'));
      if (playing) unawaited(p.play());
    } on Object {
      // Without it, the queue still catches up when the app is reopened.
      _stop();
    }
  }

  void _stop() {
    final p = _player;
    _player = null;
    p?.dispose();
  }
}
