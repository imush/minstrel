import 'didl.dart';
import 'protocol_info.dart';

enum QualityPreference {
  /// Best available: lossless over lossy, then higher resolution.
  best,

  /// Smallest stream the target can play, for metered connections. Picks a
  /// transcoded variant when the server offers one.
  dataSaver,
}

/// Formats each local player can decode. AVPlayer (iOS, macOS) has no Ogg,
/// WMA or DSD; ExoPlayer (Android) has no AIFF, WMA or DSD. Raw L16 needs a
/// WAV header that neither adds.
class LocalSinks {
  static final apple = ProtocolInfo.parseList(
    'http-get:*:audio/mpeg:*,http-get:*:audio/mp4:*,http-get:*:audio/aac:*,'
    'http-get:*:audio/flac:*,http-get:*:audio/wav:*,http-get:*:audio/aiff:*',
  );
  static final android = ProtocolInfo.parseList(
    'http-get:*:audio/mpeg:*,http-get:*:audio/mp4:*,http-get:*:audio/aac:*,'
    'http-get:*:audio/flac:*,http-get:*:audio/wav:*,http-get:*:audio/ogg:*,'
    'http-get:*:audio/opus:*',
  );
}

class ResourceSelector {
  /// Chooses the resource of [item] to send to a player that accepts
  /// [sinks], or null if none is playable. Resources without protocolInfo
  /// are tried last, on the chance the player copes.
  static DidlResource? select(
    DidlItem item,
    List<ProtocolInfo> sinks, {
    QualityPreference preference = QualityPreference.best,
  }) {
    final candidates = item.resources.where((r) {
      final p = r.protocolInfo;
      if (p == null) return false;
      if (p.protocol != 'http-get') return false;
      return sinks.any(p.playableBy);
    }).toList();

    if (candidates.isEmpty) {
      return item.resources
          .where((r) => r.protocolInfo == null && r.uri.isScheme('http'))
          .firstOrNull;
    }
    candidates.sort(switch (preference) {
      QualityPreference.best => (a, b) => _quality(b).compareTo(_quality(a)),
      QualityPreference.dataSaver => (a, b) => _size(a).compareTo(_size(b)),
    });
    return candidates.first;
  }

  static double _quality(DidlResource r) {
    final lossless = r.isLossless ? 1e12 : 0.0;
    final resolution = (r.sampleFrequency ?? 0) * (r.bitsPerSample ?? 16);
    return lossless + resolution + (r.bitrate ?? 0);
  }

  /// Approximate bytes per second; lossless streams without a bitrate are
  /// assumed to be large.
  static double _size(DidlResource r) {
    if (r.bitrate != null) return r.bitrate!.toDouble();
    if (r.isLossless) return 1e9;
    return 1e6;
  }
}
