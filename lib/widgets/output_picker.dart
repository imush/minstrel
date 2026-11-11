import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

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
        // Away from home, a player here can't fetch the home library by
        // itself. Said plainly on the row rather than asked about up front:
        // choosing a player is not yet a reason to want this.
        final relayed = app.relay.allowed;
        final away = app.homes.homes.any((h) {
          final s = app.homes.status(h);
          return s.state == HomeState.connected && !s.atHome;
        });
        String? noteFor(MediaRenderer r) {
          final notes = [
            // While the music passes through this phone the renderer can't
            // carry on without it, so that promise is left off.
            if (r.holdsQueue && !relayed) 'Keeps playing the queue on its own',
            if (relayed)
              'Home music passes through this device'
            else if (away)
              'Home music needs this device to pass it on',
          ];
          return notes.isEmpty ? null : notes.join(' · ');
        }

        final options = [
          ('local', 'This device', Icons.smartphone, null),
          for (final r in app.registry.renderers) (r.udn, r.name, Icons.speaker, noteFor(r)),
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
