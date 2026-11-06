import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:minstrel_core/minstrel_core.dart';

/// Permission for players on the network this phone is on to fetch tracks
/// from a paired home through it.
///
/// A home's tracks reach the phone over an authenticated, pinned HTTPS link
/// and are served on to the app as loopback URLs, which only this device can
/// fetch. To put them on a renderer in someone else's house the phone has to
/// serve them on that network, where anyone can reach them. That is the
/// user's decision to make, so nothing opens until they say so.
///
/// The permission is deliberately **not** saved. It lasts while the phone
/// stays on the network it was given on, and is gone after that — a visit,
/// not a setting. Keeping it would mean recognising a network again later,
/// and the only identity available without a location permission is the
/// IPv4 subnet, which is good enough to notice that nothing has changed in
/// the last minute and nowhere near good enough to tell a friend's
/// 192.168.1.0/24 from a hotel's.
class Relay extends ChangeNotifier {
  final HomeProxy proxy;

  /// How long the network may be away before the permission lapses: a Wi-Fi
  /// blip in the middle of an album shouldn't end it.
  final Duration grace;

  /// Seams for tests, which have no networks to move between.
  @visibleForTesting
  final Future<Set<String>> Function()? subnets;
  @visibleForTesting
  final Future<InternetAddress?> Function(Uri)? addressToward;

  Relay(
    this.proxy, {
    this.grace = const Duration(seconds: 45),
    this.subnets,
    this.addressToward,
  });

  /// The subnet the permission was given on, as `a.b.c`.
  String? _grantedOn;
  Uri? _base;
  Timer? _lapsing;

  /// Whether a renderer here may currently fetch home tracks through this
  /// phone.
  bool get allowed => _base != null;

  /// The network the permission covers, for display.
  String? get network => _grantedOn == null ? null : '$_grantedOn.0/24';

  /// Opens the relay for a player reached at [toward] (its description URL).
  /// Returns whether it worked: binding can fail, and a player reached over
  /// loopback or IPv6 isn't one we can serve.
  Future<bool> allow(Uri toward) async {
    final addr = await (addressToward ?? localAddressToward)(toward);
    if (addr == null) return false;
    final base = await proxy.openRelay(addr);
    if (base == null) return false;
    _lapsing?.cancel();
    _lapsing = null;
    _base = base;
    _grantedOn = _subnetOf(addr);
    notifyListeners();
    return true;
  }

  /// Takes the permission back and closes the listener.
  Future<void> revoke() async {
    if (_base == null) return;
    _lapsing?.cancel();
    _lapsing = null;
    _base = null;
    _grantedOn = null;
    await proxy.closeRelay();
    notifyListeners();
  }

  /// Checks the phone is still on the network the permission was given on,
  /// and drops it if not. Call when the network may have changed: on resume,
  /// and when discovery sees the interfaces move.
  ///
  /// Only IPv4 subnets are compared. The whole address set would be wrong:
  /// Android rotates temporary IPv6 addresses, which would take the
  /// permission away in the middle of an album for no reason.
  Future<void> recheck() async {
    final on = _grantedOn;
    if (on == null) return;
    if ((await _subnetsHere()).contains(on)) {
      _lapsing?.cancel();
      _lapsing = null;
      return;
    }
    _lapsing ??= Timer(grace, () async {
      _lapsing = null;
      if (_grantedOn != null && !(await _subnetsHere()).contains(_grantedOn)) await revoke();
    });
  }

  /// The URL to give a renderer for a home track, or null when relaying
  /// isn't allowed here.
  Uri? urlFor(Uri homeUrl) => _base == null ? null : proxy.relayFor(homeUrl);

  /// Narrows the relay to what is queued right now.
  void setQueue(Iterable<Uri> uris) => proxy.allowRelay(uris);

  static String _subnetOf(InternetAddress a) => a.rawAddress.take(3).join('.');

  /// The IPv4 subnets this device is on now. On failure, the one the
  /// permission was given on: not being able to look is no reason to take
  /// it away.
  Future<Set<String>> _subnetsHere() async {
    try {
      final injected = subnets;
      if (injected != null) return await injected();
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return {
        for (final i in ifaces)
          for (final a in i.addresses)
            if (!a.isLoopback) _subnetOf(a),
      };
    } on Object {
      final on = _grantedOn;
      return on == null ? const {} : {on};
    }
  }

  @override
  void dispose() {
    _lapsing?.cancel();
    super.dispose();
  }
}
