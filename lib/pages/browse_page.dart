import 'dart:async';

import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';
import '../widgets/cover_art.dart';
import '../widgets/mini_player.dart';
import '../widgets/output_button.dart';
import '../widgets/queue_actions.dart';

/// One level of a server's browse tree. MinimServer trees go many levels
/// deep (Composer > name > Work > Performer > ...), so this page simply
/// pushes itself again for each container.
class BrowsePage extends StatefulWidget {
  final MediaServer server;
  final String containerId;
  final String title;

  const BrowsePage(
      {super.key, required this.server, required this.containerId, required this.title});

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  static const _pageSize = 100;

  final _objects = <DidlObject>[];
  int _total = 0;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    try {
      final page = await widget.server.contentDirectory
          .browse(widget.containerId, start: _objects.length, count: _pageSize);
      _objects.addAll(page.objects);
      _total = page.totalMatches;
      _done = page.objects.isEmpty || (_total > 0 && _objects.length >= _total);
      _error = null;
    } on Object catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  /// All items in this container, loading any pages not yet fetched.
  Future<List<DidlItem>> _allItems() async {
    while (!_done && _error == null) {
      await _loadMore();
    }
    return _objects.whereType<DidlItem>().where((i) => i.isAudio).toList();
  }

  Future<void> _play(DidlItem? from) async {
    final items = await _allItems();
    if (items.isEmpty) return;
    final start = from == null ? 0 : items.indexWhere((i) => i.id == from.id);
    final services = AppServices.instance;
    final player = services.player;
    await player.playItems(items, start < 0 ? 0 : start);
    // Shown in the car's Recent tab.
    unawaited(services.car.remember(widget.server.udn, widget.containerId, widget.title, items.first.albumArt));
    if (!mounted) return;
    if (player.skipped.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${player.skipped.length} track(s) skipped: '
            '${player.output.name} can\'t play them'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _objects.whereType<DidlItem>().where((i) => i.isAudio).toList();
    final hasItems = items.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          const OutputButton(),
          if (hasItems) ...[
            IconButton(
              tooltip: 'Play all',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => _play(null),
            ),
            IconButton(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert),
              onPressed: () => showQueueActions(context,
                  title: widget.title, playNowLabel: 'Play all', tracks: _allItems),
            ),
          ],
        ],
      ),
      body: _error != null && _objects.isEmpty
          ? _ErrorView(error: _error!, homeId: widget.server.homeId, onRetry: () {
              setState(() => _error = null);
              _loadMore();
            })
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 800) _loadMore();
                return false;
              },
              child: ListView.builder(
                itemCount: _objects.length + (_done ? 0 : 1),
                itemBuilder: (context, i) {
                  if (i >= _objects.length) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return switch (_objects[i]) {
                    DidlContainer c => _ContainerTile(
                        container: c,
                        onMore: () => showQueueActions(context,
                            title: c.title,
                            tracks: () => widget.server.contentDirectory.collectTracks(c.id)),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => BrowsePage(
                                server: widget.server, containerId: c.id, title: c.title),
                          ),
                        ),
                      ),
                    DidlItem item => _ItemTile(
                        item: item,
                        onTap: () => _play(item),
                        onMore: () => showQueueActions(context,
                            title: item.title,
                            playNowLabel: 'Play from here',
                            playNow: () => _play(item),
                            tracks: () async => [item]),
                      ),
                  };
                },
              ),
            ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

class _ContainerTile extends StatelessWidget {
  final DidlContainer container;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _ContainerTile({required this.container, required this.onTap, required this.onMore});

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (container.composer != null && container.composer != container.title) container.composer!,
      if (container.performer != null && container.performer != container.title) container.performer!,
      if (container.date != null) container.date!.split('-').first,
    ].join(' · ');
    return ListTile(
      leading: CoverArt(container.albumArt, placeholder: Icons.folder),
      title: Text(container.title),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (container.childCount != null) Text('${container.childCount}'),
        IconButton(tooltip: 'More', icon: const Icon(Icons.more_vert), onPressed: onMore),
      ]),
      onTap: onTap,
      onLongPress: onMore,
    );
  }
}

class _ItemTile extends StatelessWidget {
  final DidlItem item;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _ItemTile({required this.item, required this.onTap, required this.onMore});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credits = [
      if (item.composer != null) item.composer!,
      if (item.performer != null) item.performer!,
    ].join(' · ');
    final res = item.resources.firstOrNull;
    return ListTile(
      leading: SizedBox(
        width: 48,
        child: Center(
          child: Text(item.trackNumber?.toString() ?? '',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ),
      title: Text(item.title),
      subtitle: Text(
        [credits, if (res != null) res.formatLabel].where((s) => s.isNotEmpty).join('  ·  '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(formatDuration(item.duration)),
        IconButton(tooltip: 'More', icon: const Icon(Icons.more_vert), onPressed: onMore),
      ]),
      enabled: item.isAudio,
      onTap: onTap,
      onLongPress: onMore,
    );
  }
}

class _ErrorView extends StatelessWidget {
  final Object error;
  final String? homeId;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry, this.homeId});

  /// For a server behind a home, the home's own account of the failure is
  /// more use than the SOAP error that results from it.
  String get _message {
    final status = homeId == null ? null : AppServices.instance.homes.proxy.status(homeId!);
    if (status == null || status.state == HomeState.connected) return 'The server didn\'t respond.\n$error';
    return [status.problem?.message ?? LaunchpadProblem.unreachable.message, ...status.tried].join('\n');
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text(_message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ]),
        ),
      );
}
