import 'home_proxy.dart';

/// How far from home a device may fetch video, as its launchpad says.
///
/// The launchpad decides and enforces this; the app carries it only so it
/// can grey out what it would merely be refused for. An older launchpad
/// says nothing, which reads as [home] — the closed end, which is the safe
/// way to be wrong.
enum VideoReach {
  home(''),
  direct('direct'),
  satellite('satellite');

  /// The value the launchpad uses on the wire.
  final String wire;

  const VideoReach(this.wire);

  static VideoReach byName(String? wire) =>
      VideoReach.values.where((v) => v.wire == (wire ?? '')).firstOrNull ?? VideoReach.home;

  /// Whether video may be fetched over the route [status] describes.
  bool allows(HomeStatus? status) {
    if (status == null || status.atHome) return true;
    if (status.viaSatellite) return this == VideoReach.satellite;
    return this != VideoReach.home;
  }
}
