import 'package:flutter/material.dart';

/// The format being played. When the server offers others too, such as the
/// original file behind an upsampled stream, a tap shows them, and another
/// hides them again.
class FormatChip extends StatefulWidget {
  final String format;
  final String? others;
  const FormatChip({super.key, required this.format, this.others});

  @override
  State<FormatChip> createState() => _FormatChipState();
}

class _FormatChipState extends State<FormatChip> {
  bool _showOthers = false;

  @override
  Widget build(BuildContext context) {
    final others = widget.others;
    if (others == null) return Chip(label: Text(widget.format));
    return ActionChip(
      label: Text(_showOthers ? '${widget.format} (also $others)' : widget.format, overflow: TextOverflow.ellipsis),
      onPressed: () => setState(() => _showOthers = !_showOthers),
    );
  }
}
