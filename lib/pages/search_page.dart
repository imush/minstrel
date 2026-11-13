import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';

import '../widgets/mini_player.dart';
import '../widgets/output_button.dart';
import '../widgets/queue_actions.dart';
import '../widgets/track_info.dart';
import 'browse_page.dart';

/// Searches a server's whole library when the user presses Search on the
/// keyboard: artists, albums and tracks, at any depth of the browse tree.
/// Not as they type: each search is several requests, which adds up through
/// a launchpad on a poor mobile connection, and half-typed words only
/// flash up misleading results.
class SearchPage extends StatefulWidget {
  final MediaServer server;

  const SearchPage({super.key, required this.server});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _text = TextEditingController();
  String _query = '';
  LibrarySearchResult _result = LibrarySearchResult.empty;
  bool _searching = false;
  Object? _error;

  /// Counts searches, so an answer to an older one is dropped.
  int _generation = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _search(String text) async {
    final query = text.trim();
    final generation = ++_generation;
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _result = LibrarySearchResult.empty;
        _searching = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _query = query;
      _searching = true;
    });
    try {
      final result = await widget.server.search.search(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _result = result;
        _error = null;
      });
    } on Object catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = e);
    } finally {
      if (mounted && generation == _generation) setState(() => _searching = false);
    }
  }

  void _open(DidlContainer c) => Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => BrowsePage(server: widget.server, containerId: c.id, title: c.title)),
      );

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: 'Search ${widget.server.name}', border: InputBorder.none),
          onSubmitted: _search,
        ),
        actions: const [OutputButton()],
        // Always there, so the bar keeps its shape and the field its focus.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _searching ? const LinearProgressIndicator(minHeight: 2) : const SizedBox(height: 2),
        ),
      ),
      body: _error != null
          ? _Message('The search failed.\n$_error')
          : _query.isEmpty
              ? const _Message('Search for an artist, composer, album or track.\n'
                  'Several words narrow it down: "haydn symphony 94".')
              : r.isEmpty && !_searching
                  ? _Message('Nothing found for "$_query".')
                  : ListView(
                      children: [
                        if (r.artists.isNotEmpty) ...[
                          _Header('Artists', r.artists.length),
                          for (final a in r.artists) _container(a, Icons.person),
                        ],
                        if (r.albums.isNotEmpty) ...[
                          _Header('Albums', r.albums.length),
                          for (final a in r.albums) _container(a, Icons.album),
                        ],
                        if (r.tracks.isNotEmpty) ...[
                          _Header('Tracks', r.tracks.length),
                          for (final (i, t) in r.tracks.indexed)
                            ItemTile(
                              item: t,
                              // One result plays alone; the rest of the list
                              // follows only if asked for from here.
                              onTap: () => playTracks(context, [t], 0),
                              onMore: () => showQueueActions(context,
                                  title: t.title,
                                  playNowLabel: 'Play',
                                  playNow: () => playTracks(context, [t], 0),
                                  fromHere: () async => r.tracks.sublist(i),
                                  playFromHere: () => playTracks(context, r.tracks.sublist(i), 0),
                                  info: () => showTrackInfo(context, t),
                                  tracks: () async => [t]),
                            ),
                        ],
                      ],
                    ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  Widget _container(DidlContainer c, IconData placeholder) => ContainerTile(
        container: c,
        placeholder: placeholder,
        onTap: () => _open(c),
        onMore: () => showQueueActions(context,
            title: c.title, tracks: () => widget.server.contentDirectory.collectTracks(c.id)),
      );
}

class _Header extends StatelessWidget {
  final String text;
  final int count;

  const _Header(this.text, this.count);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text('$text · $count', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;

  const _Message(this.text);

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}
