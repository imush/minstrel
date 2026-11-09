import 'dart:convert';
import 'video_reach.dart';
import 'dart:typed_data';

import 'home_proxy.dart';
import 'launchpad.dart';

/// A device paired with a home.
class PairedDevice {
  final String id;
  final String name;

  /// Who its invitation was for.
  final String? label;

  /// May invite others.
  final bool canInvite;

  /// How far from home it may fetch video.
  final VideoReach video;

  /// The id of the device whose invitation it used; null for the console.
  final String? invitedBy;
  final DateTime created;
  final DateTime? lastSeen;

  /// Invited by this device, so this device may revoke it.
  final bool mine;

  /// This device.
  final bool self;

  const PairedDevice({
    required this.id,
    required this.name,
    this.label,
    this.canInvite = false,
    this.video = VideoReach.home,
    this.invitedBy,
    required this.created,
    this.lastSeen,
    this.mine = false,
    this.self = false,
  });

  static PairedDevice fromJson(Map<String, dynamic> j) => PairedDevice(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        label: j['label'] as String?,
        canInvite: j['share'] == true,
        video: VideoReach.byName(j['video'] as String?),
        invitedBy: j['invitedBy'] as String?,
        created: DateTime.parse(j['created'] as String),
        lastSeen: j['lastSeen'] == null ? null : DateTime.parse(j['lastSeen'] as String),
        mine: j['mine'] == true,
        self: j['self'] == true,
      );
}

/// An invitation to a home, not yet used.
class HomeInvitation {
  final String id;
  final String? label;
  final DateTime expires;

  /// The pairing link, to scan as [qr] or send; only when just created.
  final String? uri;

  /// The link as a QR code (PNG); only when just created.
  final Uint8List? qr;

  /// The home has no outside address or satellite, so the invitation works
  /// on its network only.
  final bool homeOnly;

  const HomeInvitation({
    required this.id,
    this.label,
    required this.expires,
    this.uri,
    this.qr,
    this.homeOnly = false,
  });

  static HomeInvitation fromJson(Map<String, dynamic> j) {
    final qr = j['qr'] as String?;
    return HomeInvitation(
      id: j['id'] as String,
      label: (j['label'] as String?)?.isEmpty ?? true ? null : j['label'] as String,
      expires: DateTime.parse(j['expires'] as String),
      uri: j['uri'] as String?,
      qr: qr == null ? null : base64.decode(qr.substring(qr.indexOf(',') + 1)),
      homeOnly: j['homeOnly'] == true,
    );
  }
}

/// How long an invitation lasts.
enum InvitationValidity {
  /// To scan on the spot.
  tenMinutes('10m'),
  hour('1h'),
  day('1d'),
  week('7d');

  final String code;
  const InvitationValidity(this.code);
}

/// Inviting people to a home from the app, for devices the launchpad lets
/// do so ([LaunchpadInfo.canInvite]). Their invitations only ever make
/// listening devices, and they can revoke only the devices they invited.
extension HomeSharing on HomeProxy {
  /// Every device paired with home [id].
  Future<List<PairedDevice>> pairedDevices(String id) async => [
        for (final j in (await api(id, 'GET', '/api/devices') as List).cast<Map<String, dynamic>>())
          PairedDevice.fromJson(j),
      ];

  /// Unpairs a device this device invited.
  Future<void> revokeDevice(String id, String deviceId) =>
      api(id, 'DELETE', '/api/devices/${Uri.encodeComponent(deviceId)}');

  /// This device's invitations not yet used.
  Future<List<HomeInvitation>> invitations(String id) async => [
        for (final j in (await api(id, 'GET', '/api/invitations') as List).cast<Map<String, dynamic>>())
          HomeInvitation.fromJson(j),
      ];

  /// A new invitation to listen, for the person [label].
  ///
  /// [video] is capped by the launchpad at what this device holds: you
  /// cannot pass on more than you were given.
  Future<HomeInvitation> invite(String id,
          {String label = '',
          InvitationValidity valid = InvitationValidity.day,
          VideoReach video = VideoReach.home}) async =>
      HomeInvitation.fromJson(await api(id, 'POST', '/api/invitations',
          {'label': label, 'valid': valid.code, 'video': video.wire}) as Map<String, dynamic>);

  /// Changes how far from home a device this one invited may fetch video,
  /// optionally for everything invited through it as well. Capped the same
  /// way as [invite].
  Future<void> setDeviceVideo(String id, String deviceId, VideoReach video,
          {bool recursive = false}) =>
      api(id, 'PUT', '/api/devices/${Uri.encodeComponent(deviceId)}',
          {'video': video.wire, 'recursive': recursive});

  Future<void> cancelInvitation(String id, String invitationId) =>
      api(id, 'DELETE', '/api/invitations/${Uri.encodeComponent(invitationId)}');
}
