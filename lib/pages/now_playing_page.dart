import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../playback/renderer_output.dart';
import '../playback/system_volume.dart';
import '../widgets/cover_art.dart';
import '../widgets/output_picker.dart';

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final player = AppServices.instance.player;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Queue',
            icon: const Icon(Icons.queue_music),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute<void>(builder: (_) => const _QueuePage())),
          ),
        ],
      ),
      body: StreamBuilder<MediaItem?>(
        stream: player.mediaItem,
        builder: (context, snap) {
          final item = snap.data;
          if (item == null) return const Center(child: Text('Nothing playing'));
          final composer = item.extras?['composer'] as String?;
          // Everything on one screen, no scrolling: the cover takes the
          // height the rest leaves, and long titles are cut short.
          return Padding(
            padding: EdgeInsets.fromLTRB(32, 0, 32, 8 + MediaQuery.paddingOf(context).bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: LayoutBuilder(builder: (context, box) {
                    final size = math.min(box.maxWidth, box.maxHeight - 16).clamp(0.0, 420.0);
                    return size < 80
                        ? const SizedBox.shrink()
                        : Center(child: CoverArt(item.artUri, size: size));
                  }),
                ),
                if (composer != null)
                  Text(composer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
                Text(item.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge),
                if (item.artist != null)
                  Text(item.artist!,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                if (item.album != null)
                  Text(item.album!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                _Progress(duration: item.duration),
                const _Controls(),
                ListenableBuilder(
                  listenable: player.outputListenable,
                  builder: (context, _) => Column(children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (item.extras?['format'] != null)
                          Chip(label: Text(item.extras!['format'] as String)),
                        const SizedBox(width: 8),
                        ActionChip(
                          avatar: Icon(player.output.isLocal ? Icons.smartphone : Icons.speaker, size: 18),
                          label: Text(player.output.name),
                          onPressed: () => showOutputPicker(context),
                        ),
                      ],
                    ),
                    if (player.output is RendererOutput)
                      _Volume(key: ValueKey(player.output.id), output: player.output as RendererOutput)
                    else if (player.output.isLocal)
                      const _PhoneVolume(),
                  ]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Progress extends StatefulWidget {
  final Duration? duration;

  const _Progress({required this.duration});

  @override
  State<_Progress> createState() => _ProgressState();
}

class _ProgressState extends State<_Progress> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final player = AppServices.instance.player;
    return StreamBuilder<PlaybackState>(
      stream: player.playbackState,
      builder: (context, snap) {
        final pos = snap.data?.updatePosition ?? Duration.zero;
        final dur = widget.duration ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final value = _dragging ?? pos.inMilliseconds.toDouble().clamp(0.0, max);
        return Column(children: [
          Slider(
            value: max == 0 ? 0 : value,
            max: max == 0 ? 1 : max,
            onChanged: max == 0 ? null : (v) => setState(() => _dragging = v),
            onChangeEnd: (v) {
              player.seek(Duration(milliseconds: v.round()));
              setState(() => _dragging = null);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatDuration(Duration(milliseconds: value.round()))),
                Text(formatDuration(widget.duration)),
              ],
            ),
          ),
        ]);
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    final player = AppServices.instance.player;
    return StreamBuilder<PlaybackState>(
      stream: player.playbackState,
      builder: (context, snap) {
        final s = snap.data;
        final playing = s?.playing ?? false;
        final buffering = s?.processingState == AudioProcessingState.buffering;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
                iconSize: 40, icon: const Icon(Icons.skip_previous), onPressed: player.skipToPrevious),
            const SizedBox(width: 16),
            buffering
                ? const SizedBox.square(dimension: 72, child: CircularProgressIndicator())
                : IconButton.filled(
                    iconSize: 56,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed: playing ? player.pause : player.play,
                  ),
            const SizedBox(width: 16),
            IconButton(iconSize: 40, icon: const Icon(Icons.skip_next), onPressed: player.skipToNext),
          ],
        );
      },
    );
  }
}

class _Volume extends StatefulWidget {
  final RendererOutput output;

  const _Volume({super.key, required this.output});

  @override
  State<_Volume> createState() => _VolumeState();
}

/// A network player's volume, 0 to 100. Amplifiers are usually loud
/// enough at 10 to 30, so the slider follows a curve: 20 sits near its
/// middle-left instead of a fifth of the way along, giving the usual levels
/// most of its length.
class _VolumeState extends State<_Volume> {
  double? _volume;

  static double _toSlider(double volume) => math.sqrt(volume.clamp(0, 100) / 100);
  static int _toVolume(double slider) => (slider * slider * 100).round();

  @override
  void initState() {
    super.initState();
    widget.output.volume().then((v) {
      if (mounted && v != null) setState(() => _volume = v.toDouble());
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    if (_volume == null) return const SizedBox.shrink();
    return Row(children: [
      const Icon(Icons.volume_down),
      Expanded(
        child: Slider(
          value: _toSlider(_volume!),
          onChanged: (v) => setState(() => _volume = _toVolume(v).toDouble()),
          onChangeEnd: (v) => widget.output.setVolume(_toVolume(v)),
        ),
      ),
      const Icon(Icons.volume_up),
      SizedBox(width: 32, child: Text('${_volume!.round()}', textAlign: TextAlign.end)),
    ]);
  }
}

/// The phone's media volume, kept in step with the side buttons.
class _PhoneVolume extends StatefulWidget {
  const _PhoneVolume();

  @override
  State<_PhoneVolume> createState() => _PhoneVolumeState();
}

class _PhoneVolumeState extends State<_PhoneVolume> {
  double? _volume;
  bool _dragging = false;
  StreamSubscription<double>? _changes;

  @override
  void initState() {
    super.initState();
    SystemVolume.get().then((v) {
      if (mounted && v != null) setState(() => _volume = v);
    });
    _changes = SystemVolume.changes.listen((v) {
      if (mounted && !_dragging) setState(() => _volume = v);
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_volume == null) return const SizedBox.shrink();
    return Row(children: [
      const Icon(Icons.volume_down),
      Expanded(
        child: Slider(
          value: _volume!.clamp(0, 1),
          onChangeStart: (_) => _dragging = true,
          onChanged: (v) {
            setState(() => _volume = v);
            SystemVolume.set(v);
          },
          onChangeEnd: (v) {
            _dragging = false;
            SystemVolume.set(v);
          },
        ),
      ),
      const Icon(Icons.volume_up),
    ]);
  }
}

class _QueuePage extends StatelessWidget {
  const _QueuePage();

  @override
  Widget build(BuildContext context) {
    final player = AppServices.instance.player;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          IconButton(
            tooltip: 'Clear queue',
            icon: const Icon(Icons.clear_all),
            onPressed: () async {
              await player.clearQueue();
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: StreamBuilder<PlaybackState>(
        stream: player.playbackState,
        builder: (context, s) {
          final current = s.data?.queueIndex;
          return StreamBuilder<List<MediaItem>>(
            stream: player.queue,
            builder: (context, q) {
              final items = q.data ?? const [];
              return ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: items.length,
                onReorderItem: player.moveQueueItem,
                itemBuilder: (context, i) {
                  final item = items[i];
                  final playing = i == current;
                  return Dismissible(
                    key: ObjectKey(item),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Theme.of(context).colorScheme.errorContainer,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      child: const Icon(Icons.delete_outline),
                    ),
                    onDismissed: (_) => player.removeQueueItemAt(i),
                    child: ListTile(
                      selected: playing,
                      leading: SizedBox(
                        width: 32,
                        child: Center(child: playing ? const Icon(Icons.graphic_eq) : Text('${i + 1}')),
                      ),
                      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(item.displaySubtitle ?? item.artist ?? '',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(formatDuration(item.duration)),
                        // The playing track stays where it is.
                        playing
                            ? const SizedBox(width: 48)
                            : ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Icon(Icons.drag_handle),
                                ),
                              ),
                      ]),
                      onTap: () => player.skipToQueueItem(i),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
