import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:minstrel_core/minstrel_core.dart';

import 'cover_art.dart' show formatDuration;

/// Everything the server sent about a track: the usual fields first, then
/// any other tags it carried. [resource] is the format being played, when
/// there is one; otherwise the first the server lists.
Future<void> showTrackInfo(BuildContext context, DidlItem item, {DidlResource? resource}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, scroll) => SafeArea(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            children: [
              Text(item.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final (label, value) in trackInfoRows(item, resource: resource))
                _Row(label: label, value: value),
            ],
          ),
        ),
      ),
    );

/// The label and value of each line in [showTrackInfo].
List<(String, String)> trackInfoRows(DidlItem item, {DidlResource? resource}) {
  final res = resource ?? item.resources.firstOrNull;
  return [
    if (item.performer != null) ('Artist', item.performer!),
    // Roles other than the plain artist, in the order the server gave them.
    for (final role in {for (final a in item.artists) ?a.role})
      (_roleLabel(role), item.withRole(role).toSet().join(', ')),
    if (item.album != null) ('Album', item.album!),
    if (item.trackNumber != null) ('Track', '${item.trackNumber}'),
    if (item.genre != null) ('Genre', item.genre!),
    if (item.date != null) ('Date', item.date!),
    if (item.duration != null) ('Duration', formatDuration(item.duration)),
    if (res != null) ...[
      ('Format', res.formatLabel),
      if (res.mimeType != null) ('Type', res.mimeType!),
      if (res.sampleFrequency != null) ('Sample rate', '${res.sampleFrequency} Hz'),
      if (res.bitsPerSample != null) ('Bit depth', '${res.bitsPerSample} bit'),
      if (res.channels != null) ('Channels', '${res.channels}'),
      if (res.bitrate != null) ('Bitrate', '${(res.bitrate! * 8 / 1000).round()} kbit/s'),
      if (res.size != null) ('Size', _size(res.size!)),
      ('URL', res.uri.toString()),
    ],
    if (_otherFormats(item, res) case final other?) ('Also as', other),
    for (final t in item.otherTags) (_tagLabel(t), t.value),
  ];
}

/// Formats the server also offers the track in, such as a transcoded MP3.
String? _otherFormats(DidlItem item, DidlResource? res) {
  final other = {for (final r in item.resources) r.formatLabel}..remove(res?.formatLabel);
  return other.isEmpty ? null : other.join(', ');
}

/// albumArtist -> Album artist.
String _tagLabel(({String name, String? role, String value}) t) {
  final words = t.name.replaceAllMapped(RegExp('(?<=[a-z])([A-Z])'), (m) => ' ${m[1]!.toLowerCase()}');
  final label = words[0].toUpperCase() + words.substring(1);
  return t.role == null ? label : '$label (${t.role})';
}

String _roleLabel(String role) => switch (role.toLowerCase()) {
  'albumartist' => 'Album artist',
  _ => role[0].toUpperCase() + role.substring(1),
};

String _size(int bytes) => bytes >= 1 << 20
    ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).toStringAsFixed(0)} KB';

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      // Values such as the URL are handy in reports.
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $label')));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}
