import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';

enum QueueAction { playNow, playNext, addToQueue }

/// Bottom sheet offering Play now / Play next / Add to queue for a track or
/// a folder. [tracks] is called only after a choice, since collecting a
/// folder's tracks can take several requests.
Future<void> showQueueActions(
  BuildContext context, {
  required String title,
  required Future<List<DidlItem>> Function() tracks,
  String playNowLabel = 'Play now',
  Future<void> Function()? playNow,
}) async {
  final action = await showModalBottomSheet<QueueAction>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: Text(playNowLabel),
            onTap: () => Navigator.pop(context, QueueAction.playNow),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_play),
            title: const Text('Play next'),
            onTap: () => Navigator.pop(context, QueueAction.playNext),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Add to queue'),
            onTap: () => Navigator.pop(context, QueueAction.addToQueue),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  await runQueueAction(context, action, tracks: tracks, playNow: playNow);
}

/// Carries out [action], reporting the result in a snack bar.
Future<void> runQueueAction(
  BuildContext context,
  QueueAction action, {
  required Future<List<DidlItem>> Function() tracks,
  Future<void> Function()? playNow,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final player = AppServices.instance.player;
  try {
    if (action == QueueAction.playNow && playNow != null) {
      await playNow();
      return;
    }
    final items = await tracks();
    if (items.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('No tracks found')));
      return;
    }
    final added = switch (action) {
      QueueAction.playNow => await player.playItems(items, 0).then((_) => player.entries.length),
      QueueAction.playNext => await player.playNext(items),
      QueueAction.addToQueue => await player.addToQueue(items),
    };
    final skipped = player.skipped.length;
    final what = added == 1 ? '1 track' : '$added tracks';
    messenger.showSnackBar(SnackBar(
      content: Text([
        switch (action) {
          QueueAction.playNow => 'Playing $what',
          QueueAction.playNext => 'Playing $what next',
          QueueAction.addToQueue => 'Added $what to the queue',
        },
        if (skipped > 0) '$skipped skipped: ${player.output.name} can\'t play them',
      ].join('. ')),
    ));
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Couldn\'t get the tracks: $e')));
  }
}
