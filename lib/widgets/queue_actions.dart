import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';
import '../cache/cache_store.dart';
import '../download/save_copy.dart';
import '../pages/settings_page.dart' show formatBytes;
import 'relay_prompt.dart';

enum QueueAction {
  playNow,
  playNext,
  addToQueue,
  download,
  downloadAndPin,
  unpin,
  removeFromPhone,
  saveCopy,
}

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
  bool? pinned,
  bool audio = true,
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
          // Not music: there is nothing to keep for listening, so it is
          // fetched once and handed to the system's own save sheet.
          if (!audio) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Save a copy…'),
              subtitle: const Text('Choose where it goes: Downloads, Files, a drive'),
              onTap: () => Navigator.pop(context, QueueAction.saveCopy),
            ),
            const Divider(height: 1),
          ],
          // Only music is kept here: the cache exists so music plays with no
          // network, and a film or a photo neither plays nor belongs in a
          // space set aside for listening.
          if (audio && AppServices.instance.cache.enabled) ...[
            const Divider(height: 1),
            // Already here: offered as what can be done to it instead.
            if (pinned != null) ...[
              if (pinned)
                ListTile(
                  leading: const Icon(Icons.push_pin),
                  title: const Text('Unpin'),
                  subtitle: const Text('Lets it age out when room is needed'),
                  onTap: () => Navigator.pop(context, QueueAction.unpin),
                )
              else
                ListTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: const Text('Pin'),
                  subtitle: const Text('Stays until you unpin it'),
                  onTap: () => Navigator.pop(context, QueueAction.downloadAndPin),
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove from this device'),
                onTap: () => Navigator.pop(context, QueueAction.removeFromPhone),
              ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Keep on this device'),
                subtitle: const Text('Plays with no network, and ages out in time'),
                onTap: () => Navigator.pop(context, QueueAction.download),
              ),
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('Keep and pin'),
                subtitle: const Text('Stays until you unpin it'),
                onTap: () => Navigator.pop(context, QueueAction.downloadAndPin),
              ),
            ],
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

/// Deletes copies of [items] held on this phone, having asked first.
///
/// Asked because the row sits next to Play and the music may be the only
/// copy within reach — on a plane, deleting it cannot be undone until
/// there is a network again.
Future<void> _removeFromPhone(
  BuildContext context,
  ScaffoldMessengerState messenger,
  List<DidlItem> items,
) async {
  final cache = AppServices.instance.cache;
  final held = [for (final item in items) cache.heldFor(item)].whereType<CacheEntry>().toList();
  if (held.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('Not on this device')));
    return;
  }
  final what = held.length == 1 ? 'this track' : '${held.length} tracks';
  final bytes = held.fold(0, (n, e) => n + e.bytes);
  final pinned = held.where((e) => e.pinned).length;
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(held.length == 1 ? 'Remove this track?' : 'Remove ${held.length} tracks?'),
      content: Text([
        'This deletes $what from this device, freeing ${formatBytes(bytes)}.',
        if (pinned > 0)
          pinned == held.length
              ? 'They are pinned.'
              : '$pinned of them ${pinned == 1 ? 'is' : 'are'} pinned.',
        'Your library at home is untouched, but you will need a network to '
            'hear it again.',
      ].join(' ')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
      ],
    ),
  );
  if (agreed != true) return;
  for (final entry in held) {
    await cache.remove(entry.key);
  }
  messenger.showSnackBar(SnackBar(
    content: Text('Removed $what from this device · ${formatBytes(bytes)} freed'),
  ));
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
  // A folder can hold films and pictures alongside the music.
  final music = items.where((i) => i.isAudio).toList();
  if (music.isEmpty) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Only music is kept on this device'),
    ));
    return;
  }
  final skipped = items.length - music.length;
  final room = app.cacheFetcher.estimate(music);
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
  final done = app.download(music, pin: pin);
  messenger.showSnackBar(SnackBar(content: Text(_whatHappened(done, pin, room, skipped))));
}

String _tracks(int n) => n == 1 ? '1 track' : '$n tracks';

/// Says what a request actually did, rather than treating everything that
/// queued nothing as "already here": a format this device cannot play and a
/// track already waiting to be fetched are neither of them that.
String _whatHappened(
  ({int queued, int waiting, int held, int unplayable}) done,
  bool pin,
  ({int bytes, int unknown, int room}) room,
  int skipped,
) {
  final nothingDone = done.queued == 0 && done.waiting == 0;
  if (nothingDone && done.held > 0 && done.unplayable == 0) {
    return 'Already on this device';
  }
  if (nothingDone && done.held == 0 && done.unplayable > 0) {
    return 'Nothing here this device can play';
  }
  return [
    if (done.queued > 0)
      'Keeping ${_tracks(done.queued)} on this device${pin ? ', pinned' : ''}'
          '${room.unknown > 0 ? '' : ' · ${formatBytes(room.bytes)}'}',
    if (done.waiting > 0) '${_tracks(done.waiting)} already waiting',
    if (done.held > 0) '${done.held} already here',
    if (done.unplayable > 0)
      '${_tracks(done.unplayable)} this device can\'t play',
    if (skipped > 0) '$skipped not music',
  ].join(' · ');
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
    if (action == QueueAction.saveCopy) {
      if (context.mounted) await saveACopy(context, items.first);
      return;
    }
    if (action == QueueAction.unpin) {
      final cache = AppServices.instance.cache;
      var touched = 0;
      for (final item in items) {
        final held = cache.heldFor(item);
        if (held == null) continue;
        touched++;
        await cache.setPinned(held.key, false);
      }
      messenger.showSnackBar(SnackBar(
        content: Text(touched == 0
            ? 'Not on this device'
            : 'Unpinned ${touched == 1 ? '1 track' : '$touched tracks'}'),
      ));
      return;
    }
    if (action == QueueAction.removeFromPhone) {
      if (context.mounted) await _removeFromPhone(context, messenger, items);
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
      QueueAction.download ||
      QueueAction.downloadAndPin ||
      QueueAction.unpin ||
      QueueAction.removeFromPhone ||
      QueueAction.saveCopy =>
        0, // handled above
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
        QueueAction.download ||
        QueueAction.downloadAndPin ||
        QueueAction.unpin ||
        QueueAction.removeFromPhone ||
        QueueAction.saveCopy =>
          0,
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
          QueueAction.download ||
          QueueAction.downloadAndPin ||
          QueueAction.unpin ||
          QueueAction.removeFromPhone ||
          QueueAction.saveCopy =>
            '',
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
