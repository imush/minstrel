import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../pages/now_playing_page.dart';
import 'cover_art.dart';

/// Compact player shown under every page while something is queued.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = AppServices.instance.player;
    return StreamBuilder<MediaItem?>(
      stream: player.mediaItem,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: SafeArea(
            top: false,
            child: InkWell(
              onTap: () => Navigator.push(
                  context, MaterialPageRoute<void>(builder: (_) => const NowPlayingPage())),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StreamBuilder<PlaybackState>(
                    stream: player.playbackState,
                    builder: (context, s) {
                      final pos = s.data?.updatePosition ?? Duration.zero;
                      final dur = item.duration;
                      final v = dur == null || dur.inMilliseconds == 0
                          ? 0.0
                          : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
                      return LinearProgressIndicator(value: v, minHeight: 2);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        CoverArt(item.artUri, size: 44),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ListenableBuilder(
                                listenable: player.outputListenable,
                                builder: (context, _) => Text(
                                  [item.displaySubtitle ?? item.artist ?? '', 'on ${player.output.name}']
                                      .where((s) => s.isNotEmpty)
                                      .join('  ·  '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                        StreamBuilder<PlaybackState>(
                          stream: player.playbackState,
                          builder: (context, s) {
                            final playing = s.data?.playing ?? false;
                            final buffering = s.data?.processingState == AudioProcessingState.buffering;
                            if (buffering) {
                              return const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox.square(
                                    dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                              );
                            }
                            return IconButton(
                              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                              onPressed: playing ? player.pause : player.play,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
