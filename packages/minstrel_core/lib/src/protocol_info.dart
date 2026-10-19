/// A UPnP protocolInfo string: `protocol:network:contentFormat:additionalInfo`,
/// for example `http-get:*:audio/x-flac:DLNA.ORG_OP=01`.
class ProtocolInfo {
  final String protocol;
  final String network;
  final String contentFormat;
  final String additionalInfo;

  const ProtocolInfo(
      this.protocol, this.network, this.contentFormat, this.additionalInfo);

  static ProtocolInfo? parse(String? s) {
    if (s == null) return null;
    final parts = s.trim().split(':');
    if (parts.length < 3) return null;
    return ProtocolInfo(
      parts[0].trim(),
      parts[1].trim(),
      parts[2].trim(),
      parts.length > 3 ? parts.sublist(3).join(':').trim() : '*',
    );
  }

  /// Parses a comma-separated list as returned by GetProtocolInfo.
  static List<ProtocolInfo> parseList(String? s) {
    if (s == null || s.trim().isEmpty) return const [];
    return s.split(',').map(parse).whereType<ProtocolInfo>().toList();
  }

  /// MIME type without parameters, lower-cased and with common aliases
  /// folded together (audio/x-flac and audio/flac are the same thing).
  String get mimeType => normalizeMime(contentFormat);

  /// Whether a resource with this protocolInfo can be played by a sink
  /// advertising [sink].
  bool playableBy(ProtocolInfo sink) {
    if (!_fieldMatches(sink.protocol, protocol)) return false;
    if (sink.contentFormat == '*') return true;
    final sinkMime = sink.mimeType;
    if (sinkMime.endsWith('/*')) {
      return mimeType.startsWith(sinkMime.substring(0, sinkMime.length - 1));
    }
    if (sinkMime != mimeType) return false;
    // audio/L16 carries rate and channels as parameters; both must agree.
    if (mimeType == 'audio/l16') {
      return _mimeParams(sink.contentFormat)['rate'] ==
              _mimeParams(contentFormat)['rate'] &&
          _mimeParams(sink.contentFormat)['channels'] ==
              _mimeParams(contentFormat)['channels'];
    }
    return true;
  }

  static bool _fieldMatches(String pattern, String value) =>
      pattern == '*' || value == '*' || pattern == value;

  static Map<String, String> _mimeParams(String contentFormat) {
    final result = <String, String>{};
    for (final p in contentFormat.split(';').skip(1)) {
      final eq = p.indexOf('=');
      if (eq > 0) {
        result[p.substring(0, eq).trim().toLowerCase()] =
            p.substring(eq + 1).trim();
      }
    }
    return result;
  }

  @override
  String toString() => '$protocol:$network:$contentFormat:$additionalInfo';
}

const _mimeAliases = {
  'audio/x-flac': 'audio/flac',
  'audio/mp3': 'audio/mpeg',
  'audio/x-mp3': 'audio/mpeg',
  'audio/x-mpeg': 'audio/mpeg',
  'audio/m4a': 'audio/mp4',
  'audio/x-m4a': 'audio/mp4',
  'audio/x-aac': 'audio/aac',
  'audio/vnd.dlna.adts': 'audio/aac',
  'audio/wave': 'audio/wav',
  'audio/x-wav': 'audio/wav',
  'audio/vnd.wave': 'audio/wav',
  'audio/x-aiff': 'audio/aiff',
  'audio/x-ogg': 'audio/ogg',
  'application/ogg': 'audio/ogg',
  'audio/x-dsf': 'audio/dsf',
  'audio/x-dff': 'audio/dff',
  'audio/x-ms-wma': 'audio/wma',
};

String normalizeMime(String contentFormat) {
  final base = contentFormat.split(';').first.trim().toLowerCase();
  return _mimeAliases[base] ?? base;
}
