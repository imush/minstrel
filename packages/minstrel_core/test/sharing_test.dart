import 'dart:convert';

import 'package:minstrel_core/minstrel_core.dart';
import 'package:test/test.dart';

void main() {
  test('reads the launchpad\'s device list', () {
    final d = PairedDevice.fromJson(jsonDecode(
        '{"id":"ab12","name":"Anna\'s phone","label":"Anna","invitedBy":"cd34","created":"2026-10-29T10:00:00Z",'
        '"lastSeen":"2026-10-29T11:00:00Z","mine":true}') as Map<String, dynamic>);
    expect([d.name, d.label, d.invitedBy, d.mine, d.self, d.canInvite], ["Anna's phone", 'Anna', 'cd34', true, false, false]);
    expect(d.lastSeen, DateTime.utc(2026, 10, 29, 11));
  });

  test('reads a new invitation with its QR code', () {
    final png = [0x89, 0x50, 0x4e, 0x47];
    final inv = HomeInvitation.fromJson({
      'id': 'ef56',
      'label': '',
      'uri': 'minstrel://pair?v=1&c=abc',
      'expires': '2026-10-30T10:00:00Z',
      'qr': 'data:image/png;base64,${base64.encode(png)}',
      'homeOnly': true,
    });
    expect(inv.label, isNull);
    expect(inv.qr, png);
    expect(inv.homeOnly, isTrue);
  });

  test('knows whether this device may invite', () {
    expect(LaunchpadInfo.fromJson({'device': {'id': 'x', 'share': true}}).canInvite, isTrue);
    expect(LaunchpadInfo.fromJson({'device': {'id': 'x'}}).canInvite, isFalse);
    expect(LaunchpadInfo.fromJson({}).canInvite, isFalse);
  });
}
