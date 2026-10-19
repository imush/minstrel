import 'dart:io';

import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _app = AppServices.instance;

  @override
  Widget build(BuildContext context) {
    final player = _app.player;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(title: Text('Quality'), dense: true),
          RadioGroup<QualityPreference>(
            groupValue: player.preference,
            onChanged: (v) {
              if (v == null) return;
              _app.setQualityPreference(v);
              setState(() {});
            },
            child: const Column(children: [
              RadioListTile(
                value: QualityPreference.best,
                title: Text('Best available'),
                subtitle: Text('Original files, lossless where the player supports it'),
              ),
              RadioListTile(
                value: QualityPreference.dataSaver,
                title: Text('Data saver'),
                subtitle: Text('The smallest version the server offers, for cellular'),
              ),
            ]),
          ),
          if (Platform.isIOS) ...[
            const Divider(),
            SwitchListTile(
              value: player.keepAliveEnabled,
              onChanged: (v) {
                _app.setKeepAlive(v);
                setState(() {});
              },
              title: const Text('Keep speaker queues going in the background'),
              subtitle: const Text(
                'Some network speakers only accept one track at a time. To feed them the next '
                'one while Minstrel is in the background, it plays silence alongside your other '
                'audio, only while such a queue is playing. Uses a little battery. When off, '
                'the queue continues when you return to Minstrel.',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
