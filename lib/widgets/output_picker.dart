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
            (r.udn, r.name, Icons.speaker, r.holdsQueue ? 'Keeps playing the queue on its own' : null),
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
