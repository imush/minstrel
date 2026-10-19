import 'dart:async';

import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';
import '../widgets/cover_art.dart';
import '../widgets/mini_player.dart';
import 'add_home_page.dart';
import 'browse_page.dart';
import 'settings_page.dart';

/// Home: the media servers found on the network or added by URL.
class ServersPage extends StatefulWidget {
  const ServersPage({super.key});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  final _app = AppServices.instance;
  late final StreamSubscription<void> _sub;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _sub = _app.registry.changes.listen((_) => setState(() {}));
    _app.homes.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _sub.cancel();
    _app.homes.removeListener(_changed);
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _searching = true);
    await Future.wait([_app.registry.refresh(), _app.homes.refreshAll()]);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _addManual() async {
    final controller = TextEditingController(text: 'http://');
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add server by address'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Device description URL',
            helperText: 'For servers reached over a VPN, e.g.\n'
                'http://10.0.0.5:9791/<uuid>/Upnp/device.xml',
            helperMaxLines: 3,
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Add')),
        ],
      ),
    );
    final uri = url == null ? null : Uri.tryParse(url.trim());
    if (uri == null || !uri.hasAuthority) return;
    try {
      await _app.addManualDevice(uri);
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not reach $uri: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final servers = _app.registry.servers;
    final manual = _app.manualDevices.toSet();
    final homes = _app.homes.homes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minstrel'),
        actions: [
          IconButton(
            tooltip: 'Add home',
            icon: const Icon(Icons.add_home),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute<void>(builder: (_) => const AddHomePage())),
          ),
          IconButton(
            tooltip: 'Add server by address',
            icon: const Icon(Icons.add_link),
            onPressed: _addManual,
          ),
          IconButton(
            tooltip: 'Search again',
            icon: _searching
                ? const SizedBox.square(
                    dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _searching ? null : _refresh,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: [
            if (homes.isNotEmpty) ...[
              const _Header('Homes'),
              for (final h in homes) _HomeTile(home: h),
            ],
            const _Header('Music servers'),
            if (servers.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text(
                  _app.registry.localNetworkDenied
                      ? 'Minstrel isn\'t allowed to search this network. '
                          'Turn on Local Network access for Minstrel in Settings > Privacy.'
                      : 'Looking for music servers… Servers on this network appear automatically. '
                          'Away from home, pair with your home\'s launchpad (Add home), '
                          'or add a server by address over a VPN.',
                ),
              ),
            for (final s in servers)
              ListTile(
                leading: CoverArt(s.device.bestIcon?.url, size: 40, placeholder: Icons.dns),
                title: Text(s.name),
                subtitle: Text([
                  if (s.device.modelName != null) s.device.modelName!,
                  s.via != null ? 'via ${s.via}' : s.device.location.host,
                ].join(' · ')),
                trailing: manual.contains(s.device.location.toString())
                    ? IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.link_off),
                        onPressed: () async {
                          await _app.removeManualDevice(s.device.location);
                          setState(() {});
                        })
                    : null,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => BrowsePage(server: s, containerId: '0', title: s.name),
                  ),
                ),
              ),
            const _Header('Play on'),
            _OutputTile(id: 'local', name: 'This device', icon: Icons.smartphone),
            for (final r in _app.registry.renderers)
              _OutputTile(
                id: r.udn,
                name: r.name,
                icon: Icons.speaker,
                detail: [
                  if (r.device.manufacturer != null) r.device.manufacturer!,
                  r.device.location.host,
                ].join(' · '),
              ),
          ],
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;

  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary)),
      );
}

/// A place to play; tapping makes it the current output, moving anything
/// already playing there.
class _OutputTile extends StatelessWidget {
  final String id;
  final String name;
  final IconData icon;
  final String? detail;

  const _OutputTile({required this.id, required this.name, required this.icon, this.detail});

  @override
  Widget build(BuildContext context) {
    final app = AppServices.instance;
    return ListenableBuilder(
      listenable: app.player.outputListenable,
      builder: (context, _) => ListTile(
        leading: Icon(icon),
        title: Text(name),
        subtitle: detail == null ? null : Text(detail!),
        trailing: app.player.output.id == id ? const Icon(Icons.check) : null,
        onTap: () async {
          final out = app.outputFor(id);
          if (out != null) await app.player.switchOutput(out);
        },
      ),
    );
  }
}

Future<void> _rename(BuildContext context, Home home) async {
  final controller = TextEditingController(text: home.name);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename home'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(helperText: 'Leave empty to use the name set on the launchpad.'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
      ],
    ),
  );
  if (name != null) await AppServices.instance.homes.rename(home, name);
}

/// A paired home and how it's connected right now.
class _HomeTile extends StatelessWidget {
  final Home home;

  const _HomeTile({required this.home});

  @override
  Widget build(BuildContext context) {
    final homes = AppServices.instance.homes;
    final status = homes.status(home);
    final error = Theme.of(context).colorScheme.error;
    final (text, color) = switch (status.state) {
      HomeState.connecting => ('Connecting…', null),
      HomeState.connected => (
          status.atHome
              ? 'Connected on this network'
              : status.viaSatellite
                  ? 'Connected through the satellite'
                  : 'Connected from outside',
          null,
        ),
      HomeState.unreachable || HomeState.notPaired =>
        (status.problem?.message ?? LaunchpadProblem.unreachable.message, error),
    };
    return ListTile(
      leading: Icon(status.state == HomeState.connected ? Icons.home : Icons.home_outlined),
      title: Text(home.name),
      subtitle: Text(
        [
          text,
          // Which addresses were tried and what happened, to tell a closed
          // router port from a launchpad that's down.
          if (status.state == HomeState.unreachable) ...status.tried,
        ].join('\n'),
        style: color == null ? null : TextStyle(color: color),
      ),
      isThreeLine: status.state == HomeState.unreachable && status.tried.isNotEmpty,
      onTap: () => homes.refresh(home),
      trailing: PopupMenuButton<void>(
        tooltip: 'More',
        itemBuilder: (context) => [
          PopupMenuItem(
            onTap: () => _rename(context, home),
            child: const Text('Rename'),
          ),
          PopupMenuItem(
            onTap: () => homes.remove(home),
            child: const Text('Forget this home'),
          ),
        ],
      ),
    );
  }
}
