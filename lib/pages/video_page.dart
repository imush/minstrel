import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';

/// Plays one video on this device.
///
/// Deliberately apart from the audio queue: video has a surface, an
/// orientation and subtitle tracks, and none of that belongs in a player
/// built for a gapless album. Nothing here touches the audio handler, so
/// whatever was playing is left alone.
///
/// mpv is underneath, through media_kit, because it is the only option that
/// can list and switch the subtitle tracks inside a file — including the
/// image-based ones a DVD rip carries, which most players either ignore or
/// render once and then lose on the first seek.
class VideoPage extends StatefulWidget {
  final DidlItem item;
  final Uri uri;

  const VideoPage({super.key, required this.item, required this.uri});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  final _subs = <StreamSubscription<void>>[];

  /// The frame's shape, once mpv has read it. The controls are drawn over
  /// the video widget, so the widget is sized to the picture rather than
  /// the screen — otherwise the seek bar sits on the very bottom edge of
  /// the phone, in among the system gestures.
  double? _ratio;

  List<SubtitleTrack> _subtitles = const [];
  List<AudioTrack> _audios = const [];
  Track? _track;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subs.add(_player.stream.tracks.listen((t) {
      if (!mounted) return;
      setState(() {
        // "auto" and "no" are mpv's own entries, not the file's. The menu
        // offers Off itself, so only the real tracks are listed.
        _subtitles = t.subtitle.where((s) => s.id != 'auto').toList();
        _audios = t.audio.where((a) => a.id != 'auto' && a.id != 'no').toList();
      });
    }));
    _subs.add(_player.stream.track.listen((t) {
      if (mounted) setState(() => _track = t);
    }));
    _subs.add(_player.stream.width.listen((_) => _sizeChanged()));
    _subs.add(_player.stream.height.listen((_) => _sizeChanged()));
    _subs.add(_player.stream.error.listen((e) {
      if (mounted) setState(() => _error = e);
    }));
    // The iOS Simulator exposes no audio device to libmpv, and mpv abandons
    // the file rather than play it silently. Only for looking at the video
    // on a simulator: a real device must still fail loudly if it has no
    // sound, rather than play a silent film and leave you wondering.
    if (const bool.fromEnvironment('MPV_NULL_AUDIO') && _player.platform is NativePlayer) {
      unawaited((_player.platform! as NativePlayer).setProperty('ao', 'null'));
    }
    // Two things can't have this device's speaker, and a paused track left
    // in the Now Playing bar under a film is just clutter. Music on a
    // renderer is in another room and is left alone: a film here is no
    // reason to stop it there.
    final audio = AppServices.instance.player;
    if (audio.output.isLocal) unawaited(audio.clearQueue());

    unawaited(_player.open(Media(widget.uri.toString())));
    // Landscape while watching; the app is portrait-only otherwise.
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
  }

  void _sizeChanged() {
    final w = _player.state.width, h = _player.state.height;
    if (!mounted || w == null || h == null || w <= 0 || h <= 0) return;
    final ratio = w / h;
    if (_ratio != ratio) setState(() => _ratio = ratio);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_player.dispose());
    unawaited(SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  /// A track's own name, falling back to its language, then to its number.
  /// Servers and rippers are inconsistent about which they set.
  String _label(String? title, String? language, int index) {
    final parts = [
      if (title != null && title.trim().isNotEmpty) title.trim(),
      if (language != null && language.trim().isNotEmpty && language != 'und')
        languageName(language.trim()),
    ];
    return parts.isEmpty ? 'Track ${index + 1}' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_subtitles.isNotEmpty)
            PopupMenuButton<SubtitleTrack>(
              tooltip: 'Subtitles',
              icon: const Icon(Icons.closed_caption),
              onSelected: (t) => unawaited(_player.setSubtitleTrack(t)),
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: SubtitleTrack.no(),
                  checked: _track?.subtitle.id == 'no',
                  child: const Text('Off'),
                ),
                for (final (i, s) in _subtitles.indexed)
                  CheckedPopupMenuItem(
                    value: s,
                    checked: _track?.subtitle.id == s.id,
                    child: Text(_label(s.title, s.language, i)),
                  ),
              ],
            ),
          if (_audios.length > 1)
            PopupMenuButton<AudioTrack>(
              tooltip: 'Audio',
              icon: const Icon(Icons.graphic_eq),
              onSelected: (t) => unawaited(_player.setAudioTrack(t)),
              itemBuilder: (context) => [
                for (final (i, a) in _audios.indexed)
                  CheckedPopupMenuItem(
                    value: a,
                    checked: _track?.audio.id == a.id,
                    child: Text(_label(a.title, a.language, i)),
                  ),
              ],
            ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text('This video didn\'t play.\n\n$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              )
            : MaterialVideoControlsTheme(
                normal: _controls,
                fullscreen: _controls,
                child: AspectRatio(
                  // 16:9 until mpv says otherwise: a sane shape to show
                  // while the first frame is still being read.
                  aspectRatio: _ratio ?? 16 / 9,
                  child: Video(controller: _controller, controls: AdaptiveVideoControls),
                ),
              ),
      ),
    );
  }
}

/// The seek bar ships flush to the edges, where a phone's back-swipe and
/// home gestures live, so its ends are hard to grab. The button bars above
/// it already inset by 16; this gives the bar the same margin.
const _controls = MaterialVideoControlsThemeData(
  seekBarMargin: EdgeInsets.symmetric(horizontal: 16),
);
