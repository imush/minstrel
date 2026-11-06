import 'package:flutter/material.dart';

import '../app_services.dart';

/// Asks whether to pass tracks from a paired home to the player in use
/// through this phone, and opens the relay if so. Returns whether relaying
/// is allowed afterwards.
///
/// Asked here rather than offered in Settings because this is the only
/// moment it is needed: a player on someone else's network, and music that
/// lives at home. Asking when a player is merely chosen would be asking for
/// permission that most of the time isn't used, which teaches people to
/// agree without reading.
Future<bool> offerRelay(BuildContext context) async {
  final app = AppServices.instance;
  final name = app.player.output.name;
  final renderer = app.registry.renderer(app.player.output.id);
  if (renderer == null) return false;
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Play home music on $name?'),
      content: Text(
        '$name can\'t reach your home library by itself. Minstrel can pass '
        'the music through this phone.\n\n'
        'While this is on, anyone on this network can reach the tracks you '
        'have queued. The music comes over your home connection, about 1 MB '
        'a minute for CD quality, and this phone has to stay on this network '
        'with Minstrel running.\n\n'
        'Stays on until you leave this network.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Play through this phone'),
        ),
      ],
    ),
  );
  if (agreed != true) return false;
  return app.relay.allow(renderer.device.location);
}
