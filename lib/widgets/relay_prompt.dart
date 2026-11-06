import 'package:flutter/material.dart';

import '../app_services.dart';

/// What came of asking.
enum RelayOffer {
  /// Not asked for, or said no.
  declined,

  /// Agreed to, but the listener couldn't be opened: this device has no
  /// address on the player's network. Phones on Wi-Fi do; a device that
  /// runs apps in a container of their own, as a Chromebook does, may not.
  unavailable,

  /// Open; the player can fetch from here now.
  allowed,
}

/// Asks whether to pass tracks from a paired home to the player in use
/// through this phone, and opens the relay if so.
///
/// Asked here rather than offered in Settings because this is the only
/// moment it is needed: a player on someone else's network, and music that
/// lives at home. Asking when a player is merely chosen would be asking for
/// permission that most of the time isn't used, which teaches people to
/// agree without reading.
Future<RelayOffer> offerRelay(BuildContext context) async {
  final app = AppServices.instance;
  final name = app.player.output.name;
  final renderer = app.registry.renderer(app.player.output.id);
  if (renderer == null) return RelayOffer.declined;
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
  if (agreed != true) return RelayOffer.declined;
  return await app.relay.allow(renderer.device.location)
      ? RelayOffer.allowed
      : RelayOffer.unavailable;
}
