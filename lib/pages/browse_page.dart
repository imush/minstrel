import 'dart:async';

import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../app_services.dart';
import '../playback/audio_handler.dart';
import '../widgets/cover_art.dart';
import '../widgets/mini_player.dart';
import '../widgets/output_button.dart';
import '../widgets/queue_actions.dart';
import '../widgets/relay_prompt.dart';
import '../widgets/track_info.dart';
import 'search_page.dart';

/// One level of a server's browse tree. MinimServer trees go many levels
/// deep (Composer > name > Work > Performer > ...), so this page simply
/// pushes itself again for each container.
/// One step of the trail that led to the page being shown.
typedef BrowseCrumb = ({String id, String title});

class BrowsePage extends StatefulWidget {
  final MediaServer server;
  final String containerId;
  final String title;

  /// Artwork for this container, handed down by whoever pushed the page so the
  /// album image can be shown before the tracks have loaded. Falls back to the
  /// first track's art when the caller had none (search, car, a deep link).
  final Uri? albumArt;

  /// Ancestors, outermost first, excluding this page. Empty means there is
  /// nothing above us on the stack, so no breadcrumb is offered.
  final List<BrowseCrumb> path;

  const BrowsePage(
      {super.key,
      required this.server,
      required this.containerId,
      required this.title,
      this.albumArt,
      this.path = const []});

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
    // A leaf - an album's tracks, with nothing to browse into - gets one image
    // at the top, the way BubbleUPnP does it. Listings that contain containers
    // (performers, composers) keep their per-row thumbnails and get no header,
    // which is the same rule seen from the other side.
    final isLeaf = hasItems && !_objects.any((o) => o is DidlContainer);
    final headerArt = widget.albumArt ?? (hasItems ? items.first.albumArt : null);
    final showHeader = isLeaf && headerArt != null;
    return Scaffold(
      appBar: AppBar(
        title: filtering
            ? TextField(
                autofocus: true,
                decoration: InputDecoration(hintText: 'Filter ${widget.title}', border: InputBorder.none),
                onChanged: _setFilter,
              )
            : _TitleBar(title: widget.title, path: widget.path),
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
                itemCount: (showHeader ? 1 : 0) + shown.length + (_done ? 0 : 1),
                itemBuilder: (context, rawIndex) {
                  if (showHeader && rawIndex == 0) {
                    // The name lives here rather than only in the app bar: with
                    // five actions and a back button there is almost nothing
                    // left for a title up there, and album names are long
                    // ("Di..." was all that fitted). Here it gets two full
                    // lines, and the app bar is free to stay short.
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Column(children: [
                        CoverArt(headerArt, size: 160),
                        const SizedBox(height: 12),
                        Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ]),
                    );
                  }
                  final i = showHeader ? rawIndex - 1 : rawIndex;
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
                              server: widget.server,
                              containerId: c.id,
                              title: c.title,
                              albumArt: c.albumArt,
                              path: [
                                ...widget.path,
                                (id: widget.containerId, title: widget.title)
                              ],
                            ),
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
  // Tracks from a paired home need this phone to pass them on; ask, then
  // start again with the whole request so they fall into place in order.
  if (player.needRelay.isNotEmpty && context.mounted && await offerRelay(context)) {
    try {
      await player.playItems(items, start);
    } on Object catch (e) {
      if (!isConnectionError(e)) rethrow;
    }
  }
  reportLeftOut(messenger, player);
  return true;
}

/// Says what was left out of the queue and why. Two different reasons, and
/// the one that sounds like the player's fault usually isn't.
void reportLeftOut(ScaffoldMessengerState messenger, MinstrelAudioHandler player) {
  final name = player.output.name;
  final notes = [
    if (player.needRelay.isNotEmpty)
      '${player.needRelay.length} track(s) not played: $name can\'t reach your home library',
    if (player.skipped.isNotEmpty)
      '${player.skipped.length} track(s) skipped: $name can\'t play them',
  ];
  if (notes.isNotEmpty) messenger.showSnackBar(SnackBar(content: Text(notes.join('. '))));
}

/// Opens a search of the whole library, on servers that can search.
/// The app bar title. One level deep it is just text; deeper in it becomes a
/// button opening the trail, so you can jump several levels back at once
/// instead of tapping Back repeatedly.
///
/// Deliberately a menu rather than a breadcrumb bar: a bar costs a row of
/// vertical space on every screen, and the same testers asking for this asked
/// for denser listings in the same breath.
class _TitleBar extends StatelessWidget {
  final String title;
  final List<BrowseCrumb> path;

  const _TitleBar({required this.title, required this.path});

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty) return Text(title);
    return PopupMenuButton<int>(
      tooltip: 'Go back to',
      position: PopupMenuPosition.under,
      // Pop (depth - index) routes. No route names needed: the pages are a
      // plain stack, so counting down is enough and leaves the ancestors'
      // scroll positions intact.
      onSelected: (index) {
        var n = path.length - index;
        Navigator.of(context).popUntil((_) => n-- <= 0);
      },
      itemBuilder: (context) => [
        for (final (i, crumb) in path.indexed)
          PopupMenuItem<int>(
            value: i,
            child: Row(children: [
              SizedBox(width: 16.0 * i),
              if (i > 0) const Icon(Icons.subdirectory_arrow_right, size: 16),
              const SizedBox(width: 4),
              Flexible(child: Text(crumb.title, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
        const Icon(Icons.arrow_drop_down),
      ]),
    );
  }
}

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
    // Title only. Composer, performer and format used to sit under every row,
    // which pushed each track to three lines and fitted three tracks on a
    // phone screen; the same information is one tap away under Info. Testers
    // asked for denser listings and this is most of the space back.
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      minLeadingWidth: 0,
      horizontalTitleGap: 8,
      leading: SizedBox(
        width: 24,
        child: Text(
          item.trackNumber?.toString() ?? '',
          textAlign: TextAlign.right,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(formatDuration(item.duration), style: theme.textTheme.bodySmall),
        IconButton(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert),
          visualDensity: VisualDensity.compact,
          onPressed: onMore,
        ),
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
