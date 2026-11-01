import 'dart:async';

import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';
import '../widgets/cover_art.dart';
import '../widgets/mini_player.dart';
import '../widgets/output_button.dart';
import '../widgets/queue_actions.dart';
import '../widgets/track_info.dart';
import 'search_page.dart';

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

  /// The page being fetched, which callers wait for rather than start
  /// another.
  Future<void>? _loading;
  bool _done = false;
  Object? _error;

  /// What the list is filtered by; null while the filter field is closed.
  String? _filter;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  void _setFilter(String? text) {
    setState(() => _filter = text);
    // The filter covers the whole list, not just the pages seen so far.
    if (text != null && text.isNotEmpty) unawaited(_loadAll());
  }

  Future<void> _loadAll() async {
    while (!_done && _error == null && mounted) {
      await _loadMore();
    }
  }

  List<DidlObject> get _shown {
    final words = foldForSearch(_filter ?? '').split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return _objects;
    return _objects.where((o) {
      final text = foldForSearch([
        o.title,
        if (o is DidlItem) ...[?o.performer, ?o.composer, ?o.album],
        if (o is DidlContainer) ...[?o.performer, ?o.composer],
      ].join(' '));
      return words.every(text.contains);
    }).toList();
  }

  /// Fetches the next page. While one is on its way this returns it, so
  /// [_loadAll] waits for it instead of spinning.
  Future<void> _loadMore() {
    if (_done) return Future.value();
    return _loading ??= _fetchPage().whenComplete(() {
      _loading = null;
      if (mounted) setState(() {});
    });
  }

  Future<void> _fetchPage() async {
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
  }

  /// All items in this container, loading any pages not yet fetched.
  Future<List<DidlItem>> _allItems() async {
    await _loadAll();
    return _objects.whereType<DidlItem>().where((i) => i.isAudio).toList();
  }

  Future<void> _play(DidlItem? from) async {
    final items = await _allItems();
    if (items.isEmpty || !mounted) return;
    final start = from == null ? 0 : items.indexWhere((i) => i.id == from.id);
    if (!await playTracks(context, items, start < 0 ? 0 : start)) return;
    // Shown in the car's Recent tab.
    unawaited(AppServices.instance.car
        .remember(widget.server.udn, widget.containerId, widget.title, items.first.albumArt));
  }

  @override
  Widget build(BuildContext context) {
    final items = _objects.whereType<DidlItem>().where((i) => i.isAudio).toList();
    final hasItems = items.isNotEmpty;
    final shown = _shown;
    final filtering = _filter != null;
    return Scaffold(
      appBar: AppBar(
        title: filtering
            ? TextField(
                autofocus: true,
                decoration: InputDecoration(hintText: 'Filter ${widget.title}', border: InputBorder.none),
                onChanged: _setFilter,
              )
            : Text(widget.title),
        actions: [
          if (filtering)
            IconButton(tooltip: 'Close filter', icon: const Icon(Icons.close), onPressed: () => _setFilter(null))
          else if (_objects.length > 12 || !_done)
            IconButton(tooltip: 'Filter', icon: const Icon(Icons.filter_list), onPressed: () => _setFilter('')),
          if (!filtering) _SearchButton(server: widget.server),
          const OutputButton(),
          if (hasItems && !filtering) ...[
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
                itemCount: shown.length + (_done ? 0 : 1),
                itemBuilder: (context, i) {
                  if (i >= shown.length) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return switch (shown[i]) {
                    DidlContainer c => ContainerTile(
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
                    DidlItem item => ItemTile(
                        item: item,
                        onTap: () => _play(item),
                        onMore: () => showQueueActions(context,
                            title: item.title,
                            playNowLabel: 'Play from here',
                            playNow: () => _play(item),
                            info: () => showTrackInfo(context, item),
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

/// Plays [items] from [start], reporting a player out of reach or tracks it
/// can't play. Returns whether playback started.
Future<bool> playTracks(BuildContext context, List<DidlItem> items, int start) async {
  final player = AppServices.instance.player;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await player.playItems(items, start);
  } on Object catch (e) {
    if (!isConnectionError(e)) rethrow;
    // Typically a player at home, chosen before leaving the house.
    messenger.showSnackBar(SnackBar(
      content: Text('Can\'t reach ${player.output.name}. Choose another output to play here.'),
    ));
    return false;
  }
  if (player.skipped.isNotEmpty) {
    messenger.showSnackBar(SnackBar(
      content: Text('${player.skipped.length} track(s) skipped: ${player.output.name} can\'t play them'),
    ));
  }
  return true;
}

/// Opens a search of the whole library, on servers that can search.
class _SearchButton extends StatefulWidget {
  final MediaServer server;

  const _SearchButton({required this.server});

  @override
  State<_SearchButton> createState() => _SearchButtonState();
}

class _SearchButtonState extends State<_SearchButton> {
  late final _supported = widget.server.search.supported.catchError((_) => false);

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _supported,
        builder: (context, snap) => snap.data != true
            ? const SizedBox.shrink()
            : IconButton(
                tooltip: 'Search ${widget.server.name}',
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute<void>(builder: (_) => SearchPage(server: widget.server))),
              ),
      );
}

class ContainerTile extends StatelessWidget {
  final DidlContainer container;
  final VoidCallback onTap;
  final VoidCallback onMore;

  /// Shown when the container has no artwork.
  final IconData placeholder;

  const ContainerTile(
      {super.key, required this.container, required this.onTap, required this.onMore, this.placeholder = Icons.folder});

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (container.composer != null && container.composer != container.title) container.composer!,
      if (container.performer != null && container.performer != container.title) container.performer!,
      if (container.date != null) container.date!.split('-').first,
    ].join(' · ');
    return ListTile(
      leading: CoverArt(container.albumArt, placeholder: placeholder),
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

class ItemTile extends StatelessWidget {
  final DidlItem item;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const ItemTile({super.key, required this.item, required this.onTap, required this.onMore});

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
