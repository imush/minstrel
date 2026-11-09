import 'home_proxy.dart';

/// How far from home a device may fetch video, as its launchpad says.
///
/// The launchpad decides and enforces this; the app carries it only so it
/// can grey out what it would merely be refused for. An older launchpad
/// says nothing, which reads as [home] — the closed end, which is the safe
/// way to be wrong.
enum VideoReach {
  home('', 'Home network only', 'at home',
      'Video plays only on the same network as the server. Music is unaffected.'),
  direct('direct', 'Also from outside', 'from outside',
      'Also when the phone reaches home itself. About a gigabyte an hour, on '
          'the home connection.'),
  satellite('satellite', 'Also through the satellite', 'satellite too',
      'Also when the satellite is the only way in. It carries every byte, on '
          'the relay its owner runs.');

  /// The value the launchpad uses on the wire.
  final String wire;

  /// For a menu or a radio button.
  final String label;

  /// For a line that already has other words on it.
  final String short;

  /// What choosing it costs, in one sentence.
  final String note;

  const VideoReach(this.wire, this.label, this.short, this.note);

  static VideoReach byName(String? wire) =>
      VideoReach.values.where((v) => v.wire == (wire ?? '')).firstOrNull ?? VideoReach.home;

  /// Whether video may be fetched over the route [status] describes.
  bool allows(HomeStatus? status) {
    if (status == null || status.atHome) return true;
    if (status.viaSatellite) return this == VideoReach.satellite;
    return this != VideoReach.home;
  }
}
