import 'package:flutter/material.dart';

import '../app_services.dart';
import 'output_picker.dart';

/// App bar button showing where audio plays; opens the output picker.
class OutputButton extends StatelessWidget {
  const OutputButton({super.key});

  @override
  Widget build(BuildContext context) {
    final player = AppServices.instance.player;
    return ListenableBuilder(
      listenable: player.outputListenable,
      builder: (context, _) {
        final out = player.output;
        return IconButton(
          tooltip: 'Play on: ${out.name}',
          icon: Icon(out.isLocal ? Icons.smartphone : Icons.speaker),
          color: out.isLocal ? null : Theme.of(context).colorScheme.primary,
          onPressed: () => showOutputPicker(context),
        );
      },
    );
  }
}
