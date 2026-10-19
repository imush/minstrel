import 'package:flutter/material.dart';

/// Album art from a media server, with a placeholder while loading or when
/// the server has none.
class CoverArt extends StatelessWidget {
  final Uri? uri;
  final double size;
  final IconData placeholder;

  const CoverArt(this.uri,
      {super.key, this.size = 48, this.placeholder = Icons.music_note});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHighest,
      child: Icon(placeholder, size: size * 0.5, color: scheme.onSurfaceVariant),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size > 100 ? 12 : 4),
      child: uri == null
          ? fallback
          : Image.network(
              uri.toString(),
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (_, _, _) => fallback,
              frameBuilder: (_, child, frame, sync) =>
                  sync || frame != null ? child : fallback,
            ),
    );
  }
}

String formatDuration(Duration? d) {
  if (d == null) return '';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}
