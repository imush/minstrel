/// Parses UPnP time strings such as `0:04:23.974`, `01:02:03` or `263.9`.
/// Returns null for empty, `NOT_IMPLEMENTED` and other unparseable values.
Duration? parseUpnpDuration(String? s) {
  if (s == null) return null;
  s = s.trim();
  if (s.isEmpty) return null;
  final parts = s.split(':');
  if (parts.length > 3) return null;
  var seconds = 0.0;
  for (final p in parts) {
    final v = double.tryParse(p);
    if (v == null || v < 0) return null;
    seconds = seconds * 60 + v;
  }
  return Duration(microseconds: (seconds * 1000000).round());
}

/// Formats as `H:MM:SS`, the form AVTransport Seek(REL_TIME) expects.
String formatUpnpDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}
