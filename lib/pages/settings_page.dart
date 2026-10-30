import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_services.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _original = 'original';
  final _app = AppServices.instance;

  /// Which homes can compress: it needs ffmpeg on their launchpad.
  String _compressionNote() {
    const what = 'Music from home played on this phone over mobile data or elsewhere. '
        'Players and music at home always get the original.';
    final homes = _app.homes.homes;
    if (homes.isEmpty) return what;
    final able = homes.where((h) => _app.homes.proxy.canCompress(h.id)).map((h) => h.name).toList();
    if (able.length == homes.length) return what;
    if (able.isEmpty) return '$what\n\nNone of your homes\' launchpads can compress yet (it needs ffmpeg), so originals are sent.';
    return '$what\n\nOnly ${able.join(', ')} can compress; others send originals.';
  }

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
          const Divider(),
          const ListTile(title: Text('Away from home'), dense: true),
          ListTile(
            subtitle: Text(_compressionNote()),
            dense: true,
          ),
          RadioGroup<String>(
            groupValue: _app.compression ?? _original,
            onChanged: (v) {
              if (v == null) return;
              _app.setCompression(v == _original ? null : v);
              setState(() {});
            },
            child: const Column(children: [
              RadioListTile(
                value: _original,
                title: Text('Original quality'),
                subtitle: Text('Lossless files as they are, about 1 MB a minute for CD quality'),
              ),
              RadioListTile(value: 'aac-320', title: Text('High'), subtitle: Text('AAC 320 kbit/s, about 2.4 MB a minute')),
              RadioListTile(value: 'aac-256', title: Text('Very good'), subtitle: Text('AAC 256 kbit/s, about 1.9 MB a minute')),
              RadioListTile(value: 'aac-192', title: Text('Good'), subtitle: Text('AAC 192 kbit/s, about 1.4 MB a minute')),
              RadioListTile(value: 'aac-128', title: Text('Data saver'), subtitle: Text('AAC 128 kbit/s, about 1 MB a minute')),
            ]),
          ),
          const Divider(),
          const AppVersion(),
        ],
      ),
    );
  }
}

/// The version and build, for reports from testers.
class AppVersion extends StatelessWidget {
  const AppVersion({super.key});

  static final _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _info,
        builder: (context, snap) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            snap.hasData ? 'Minstrel ${snap.data!.version} (build ${snap.data!.buildNumber})' : '',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
}
