import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';
import '../pages/settings_page.dart' show formatBytes;
import 'relay_prompt.dart';

enum QueueAction { playNow, playNext, addToQueue, download, downloadAndPin }

/// Bottom sheet offering Play now / Play next / Add to queue for a track or
/// a folder. [tracks] is called only after a choice, since collecting a
/// folder's tracks can take several requests. With [info], a track's sheet
/// also offers its details.
Future<void> showQueueActions(
  BuildContext context, {
  required String title,
  required Future<List<DidlItem>> Function() tracks,
  String playNowLabel = 'Play now',
  Future<void> Function()? playNow,
  VoidCallback? info,
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
          if (AppServices.instance.cache.enabled) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Keep on this phone'),
              subtitle: const Text('Plays with no network, and ages out in time'),
              onTap: () => Navigator.pop(context, QueueAction.download),
            ),
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: const Text('Keep and pin'),
              subtitle: const Text('Stays until you unpin it'),
              onTap: () => Navigator.pop(context, QueueAction.downloadAndPin),
            ),
            const Divider(height: 1),
          ],
          if (info != null)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Track info'),
              onTap: () {
                Navigator.pop(context);
                info();
              },
            ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  await runQueueAction(context, action, tracks: tracks, playNow: playNow);
}

/// Keeps [items] on this phone, for a flight or a drive out of signal.
///
/// Says up front when they will not fit. Without that, the last tracks of
/// an album would evict its first ones and the download would look as
/// though it had worked.
Future<void> _keepOnPhone(
  BuildContext context,
  ScaffoldMessengerState messenger,
  List<DidlItem> items, {
  required bool pin,
}) async {
  final app = AppServices.instance;
  final room = app.cacheFetcher.estimate(items);
  if (room.bytes > room.room) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Not enough room'),
        content: Text(
          'This needs ${formatBytes(room.bytes)} and there is '
          '${formatBytes(room.room)} to spare. Allow more room for music in '
          'Settings, or unpin some of what is already here.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
    return;
  }
  final added = app.download(items, pin: pin);
  messenger.showSnackBar(SnackBar(
    content: Text(added == 0
        ? 'Already on this phone'
        : 'Keeping ${added == 1 ? '1 track' : '$added tracks'} on this phone'
            '${pin ? ', pinned' : ''}'
            '${room.unknown > 0 ? '' : ' · ${formatBytes(room.bytes)}'}'),
  ));
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
    if (action == QueueAction.download || action == QueueAction.downloadAndPin) {
      if (context.mounted) {
        await _keepOnPhone(context, messenger, items,
            pin: action == QueueAction.downloadAndPin);
      }
      return;
    }
    var added = switch (action) {
      QueueAction.playNow => await player.playItems(items, 0).then((_) => player.entries.length),
      QueueAction.playNext => await player.playNext(items),
      QueueAction.addToQueue => await player.addToQueue(items),
      QueueAction.download || QueueAction.downloadAndPin => 0, // handled above
    };
    // Tracks from a paired home only reach a renderer if this phone passes
    // them on. Play now replaced the queue, so it can simply run again;
    // the other two already added what they could, so only the tracks left
    // out go in, or they would go in twice.
    final pending = player.needRelay;
    if (pending.isNotEmpty && context.mounted && await offerRelay(context) == RelayOffer.allowed) {
      warnIfPlayerCannotReachUs(messenger);
      added += switch (action) {
        QueueAction.playNow => await player.playItems(items, 0).then((_) => player.entries.length - added),
        QueueAction.playNext => await player.playNext(pending),
        QueueAction.addToQueue => await player.addToQueue(pending),
        QueueAction.download || QueueAction.downloadAndPin => 0,
      };
    }
    final what = added == 1 ? '1 track' : '$added tracks';
    final name = player.output.name;
    messenger.showSnackBar(SnackBar(
      content: Text([
        switch (action) {
          QueueAction.playNow => 'Playing $what',
          QueueAction.playNext => 'Playing $what next',
          QueueAction.addToQueue => 'Added $what to the queue',
          QueueAction.download || QueueAction.downloadAndPin => '',
        },
        if (player.needRelay.isNotEmpty)
          '${player.needRelay.length} left out: $name can\'t reach your home library',
        if (player.skipped.isNotEmpty) '${player.skipped.length} skipped: $name can\'t play them',
      ].join('. ')),
    ));
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Couldn\'t get the tracks: $e')));
  }
}
