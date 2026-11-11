import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_services.dart';
import '../cache/cache_store.dart';
import '../cache/device_storage.dart';
import 'offline_page.dart';

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
    const what = 'Music from home played on this device over mobile data or elsewhere. '
        'Music at home, and anything passed on to a player on this network, '
        'always gets the original.';
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
          // Not a saved preference: it lasts while the phone is on the
          // network it was given on. Shown only where it means something,
          // and the subtitle has to say it doesn't stick, or it reads as a
          // bug when it comes back off.
          if (_app.relay.allowed)
            SwitchListTile(
              value: true,
              title: const Text('Play home music on players here'),
              subtitle: Text('On for this network (${_app.relay.network}). '
                  'Anyone on it can reach the tracks you have queued. '
                  'Turns off by itself when you leave.'),
              onChanged: (_) async {
                await _app.relay.revoke();
                if (mounted) setState(() {});
              },
            ),
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
          const _OfflineCache(),
          const Divider(),
          const AppVersion(),
        ],
      ),
    );
  }
}

/// Music kept on this phone, so it plays away from home and when home
/// can't be reached.
class _OfflineCache extends StatefulWidget {
  const _OfflineCache();

  @override
  State<_OfflineCache> createState() => _OfflineCacheState();
}

class _OfflineCacheState extends State<_OfflineCache> {
  final _app = AppServices.instance;
  Future<StorageSpace?> _space = DeviceStorage.space();

  /// While a finger is on the slider, what it says rather than what is set.
  double? _dragging;

  void _remeasure() => setState(() => _space = DeviceStorage.space());

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _app.cache,
        builder: (context, _) => FutureBuilder<StorageSpace?>(
          future: _space,
          builder: (context, snap) => _section(context, snap.data),
        ),
      );

  Widget _section(BuildContext context, StorageSpace? space) {
    final cache = _app.cache;
    final on = cache.enabled;
    final held = cache.bytes;
    final budgetGb = (cache.budget / gigabyte).round();
    // The slider can reach whatever is free plus what the cache already
    // holds, since that space comes back as it is re-used.
    final roomGb = ((space?.free ?? 0) + held) ~/ gigabyte;
    final maxGb = [roomGb, budgetGb, 1].reduce((a, b) => a > b ? a : b).clamp(1, 512);
    final showGb = (_dragging ?? budgetGb.toDouble()).clamp(1, maxGb).round();
    final dim = on ? null : TextStyle(color: Theme.of(context).disabledColor);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(title: Text('Offline'), dense: true),
        SwitchListTile(
          value: on,
          title: const Text('Keep music on this device'),
          subtitle: const Text(
              'Tracks you play are saved while you are at home, so they play '
              'away from home and when home can\'t be reached.'),
          onChanged: (v) => v ? _turnOn() : _turnOff(context),
        ),
        ListTile(
          title: Text('Room for music', style: dim),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Slider(
                value: showGb.toDouble(),
                min: 1,
                max: maxGb.toDouble(),
                divisions: maxGb > 1 ? maxGb - 1 : null,
                label: '$showGb GB',
                onChanged:
                    on ? (v) => setState(() => _dragging = v) : null,
                onChangeEnd: (v) async {
                  final wanted = v.round() * gigabyte;
                  // Dropping this clears the slider back to what is stored,
                  // which is what shows if the change is turned down.
                  setState(() => _dragging = null);
                  if (wanted < cache.bytes && !await _confirmShrink(context, wanted)) {
                    return;
                  }
                  await _app.setCacheBudget(wanted);
                  _remeasure();
                },
              ),
              Text(_summary(held, showGb * gigabyte, space), style: dim),
            ],
          ),
        ),
        if (on) ..._notices(context, space),
        ListTile(
          leading: const Icon(Icons.library_music_outlined),
          title: Text('See what is here', style: dim),
          onTap: on
              ? () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const OfflinePage()))
              : null,
        ),
        if (on && held > 0)
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Clear it now'),
            subtitle: Text('Frees ${formatBytes(held)}'),
            onTap: () => _clear(context),
          ),
      ],
    );
  }

  /// What is held, what it may grow to, and what the phone has left.
  String _summary(int held, int budget, StorageSpace? space) {
    final line = 'Holding ${formatBytes(held)} of ${formatBytes(budget)}';
    return space == null ? line : '$line · ${formatBytes(space.free)} free on this device';
  }

  /// Why nothing is being saved, when that is the case. Worth saying: the
  /// feature looks broken otherwise.
  List<Widget> _notices(BuildContext context, StorageSpace? space) {
    final cache = _app.cache;
    final String? why;
    if (space != null && space.full >= CacheStore.brake) {
      why = 'This phone is nearly full, so nothing new is being saved. '
          'Clear the cache, or remove other files, to start again.';
    } else if (cache.budget <= 0) {
      why = 'No room is set aside, so nothing is being saved.';
    } else if (cache.pinnedFillBudget) {
      why = 'Pinned music fills the space, so nothing new is being saved. '
          'Unpin something, or allow more room.';
    } else {
      why = null;
    }
    if (why == null) return const [];
    return [
      ListTile(
        leading: Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.error),
        title: Text(why, style: Theme.of(context).textTheme.bodyMedium),
      ),
    ];
  }

  /// Asks before lowering the limit past what is already held, since that
  /// deletes music rather than only limiting what is kept in future.
  Future<bool> _confirmShrink(BuildContext context, int wanted) async {
    final cache = _app.cache;
    // Pins are not evicted, so they are not what gets freed.
    final loose = cache.bytes - cache.pinnedBytes;
    final going = (cache.bytes - wanted).clamp(0, loose);
    final stuck = cache.pinnedBytes > wanted;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(going > 0 ? 'Remove ${formatBytes(going)} of music?' : 'Allow less room?'),
        content: Text([
          if (going > 0)
            'Lowering the limit to ${formatBytes(wanted)} removes about '
                '${formatBytes(going)}, the least recently played first.'
          else
            'Everything here is pinned, so nothing can be removed to fit '
                '${formatBytes(wanted)}.',
          if (cache.pinnedBytes > 0 && going > 0) 'Pinned music is kept.',
          if (stuck)
            'Pinned music alone takes ${formatBytes(cache.pinnedBytes)}, so '
                'nothing new will be kept until you unpin some.',
        ].join(' ')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(going > 0 ? 'Remove' : 'Allow less')),
        ],
      ),
    );
    return agreed == true;
  }

  Future<void> _turnOn() async {
    await _app.setCacheEnabled(true);
    _remeasure();
  }

  /// Turning it off deletes what is held, so it asks first.
  Future<void> _turnOff(BuildContext context) async {
    final cache = _app.cache;
    if (cache.bytes > 0 && !await _confirm(context, 'Stop keeping music here?')) return;
    await _app.setCacheEnabled(false);
    _remeasure();
  }

  Future<void> _clear(BuildContext context) async {
    if (!await _confirm(context, 'Clear the music kept here?')) return;
    await _app.cache.clear();
    _remeasure();
  }

  Future<bool> _confirm(BuildContext context, String title) async {
    final cache = _app.cache;
    final pinned = cache.entries.where((e) => e.pinned).length;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(
          'This deletes the ${formatBytes(cache.bytes)} of music on this device'
          '${pinned == 0 ? '' : ', including $pinned pinned ${pinned == 1 ? 'track' : 'tracks'}'}.\n\n'
          'Your library at home is untouched, and anything you play again is '
          'saved afresh.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    return agreed == true;
  }
}

/// Sizes as people read them: tenths of a gigabyte until it is big enough
/// not to matter, megabytes below that.
String formatBytes(int bytes) {
  if (bytes >= gigabyte) {
    final gb = bytes / gigabyte;
    return gb < 10 ? '${gb.toStringAsFixed(1)} GB' : '${gb.round()} GB';
  }
  return '${(bytes / (1024 * 1024)).round()} MB';
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
