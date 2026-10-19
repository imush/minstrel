import 'dart:io';

import 'package:flutter/material.dart';

import '../app_services.dart';

/// Bottom sheet for choosing where audio plays. Switching carries the queue
/// and position over to the new output.
Future<void> showOutputPicker(BuildContext context) async {
  final app = AppServices.instance;
  await app.registry.refresh();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => StreamBuilder<void>(
      stream: app.registry.changes,
      builder: (context, _) {
        final current = app.player.output.id;
        final options = [
          ('local', 'This device', Icons.smartphone, null),
          for (final r in app.registry.renderers)
            (r.udn, r.name, Icons.speaker, _queueNote(r.holdsQueue, app.player.keepAliveEnabled)),
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('Play on'),
              ),
              for (final (id, name, icon, note) in options)
                ListTile(
                  leading: Icon(icon),
                  title: Text(name),
                  subtitle: note == null ? null : Text(note),
                  trailing: id == current ? const Icon(Icons.check) : null,
                  onTap: () async {
                    Navigator.pop(context);
                    final out = app.outputFor(id);
                    if (out != null) await app.player.switchOutput(out);
                  },
                ),
            ],
          ),
        );
      },
    ),
  );
}

/// Whether the renderer can carry on through the queue without the phone.
/// Only worth saying on iOS, where a phone-held queue stops advancing once
/// the app is suspended; Android keeps the app running while it plays.
String? _queueNote(bool holdsQueue, bool keepAlive) {
  if (holdsQueue) return 'Keeps playing the queue on its own';
  if (Platform.isIOS && !keepAlive) return 'Keep Minstrel open to play past the next track';
  return null;
}
