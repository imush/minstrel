import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:rxdart/rxdart.dart';

import '../car/car_library.dart';
import '../car/car_services.dart';
import 'keep_alive.dart';
import 'local_output.dart';
import 'output.dart';
import 'renderer_output.dart';

/// The single place playback is controlled from: the app UI, the lock
/// screen and notification, headset buttons and (later) Android Auto and
/// CarPlay. It owns the queue and drives whichever [Output] is active.
class MinstrelAudioHandler extends BaseAudioHandler with SeekHandler {
  final LocalOutput localOutput = LocalOutput();
  late Output _output = localOutput;

  /// Notifies when playback moves to a different output.
  late final ValueNotifier<Output> outputListenable = ValueNotifier(_output);
  StreamSubscription<OutputState>? _sub;

  /// iOS only: holds the app awake while it feeds a renderer track by track.
  final KeepAlive? _keepAlive = Platform.isIOS ? KeepAlive() : null;

  /// User setting; when off, a phone-held renderer queue pauses its
  /// handovers while iOS has the app suspended and catches up on reopening.
  bool keepAliveEnabled = true;

  List<QueueEntry> _entries = const [];
  QualityPreference preference = QualityPreference.best;

  /// Items from the last request that no resource could be found for.
  List<DidlItem> skipped = const [];

  /// A queue that's shown but not yet loaded into the output: restored
  /// after a restart, or kept when the renderer had moved on to something
  /// else. Play (or picking a track) loads it from here.
  int _pendingIndex = -1;
  Duration _pendingPosition = Duration.zero;

  /// The output a pending queue was restored from; only that output may
  /// replace it with what it's playing.
  String? _restoredFrom;

  /// Receives the queue to save, a couple of seconds after it changes and
  /// periodically during playback.
  void Function(QueueSnapshot)? onSnapshot;
  Timer? _saveTimer;
  DateTime _savedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _savedIndex = -1;

  MinstrelAudioHandler() {
    _listen();
  }

  /// The car's menus. Android Auto may connect while the app is still
  /// starting, so its requests wait for this.
  final _car = Completer<CarLibrary>();

  void attachCar(CarLibrary car) {
    _car.complete(car);
    car.changed.listen((id) => _carChanges[id == CarLibrary.top ? AudioService.browsableRootId : id]?.add(const {}));
  }

  final _carChanges = <String, BehaviorSubject<Map<String, dynamic>>>{};

  /// Tells Android Auto to ask again when a list it shows has changed, such
  /// as servers found after the car started the app.
  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) =>
      _carChanges.putIfAbsent(parentMediaId, BehaviorSubject.new);

  static const _resumeId = 'resume';

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    final car = await _car.future;
    try {
      if (parentMediaId == AudioService.browsableRootId) return car.roots().map(carMediaItem).toList();
      if (parentMediaId == AudioService.recentRootId) {
        // Android's "resume playback" suggestion: the current track.
        final item = mediaItem.value;
        return item == null ? const [] : [item.copyWith(id: _resumeId, playable: true, artUri: carArt(item.artUri))];
      }
      final page = options?['android.media.browse.extra.PAGE'] as int?;
      final size = options?['android.media.browse.extra.PAGE_SIZE'] as int?;
      return (await car.children(parentMediaId, page: page, pageSize: size)).map(carMediaItem).toList();
    } on Object catch (e) {
      debugPrint('car: browsing $parentMediaId failed: $e');
      return const [];
    }
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async =>
      (await (await _car.future).search(query)).map(carMediaItem).toList();

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final car = await _car.future;
    if (mediaId == _resumeId) {
      await car.player.resume();
    } else {
      await car.play(mediaId);
    }
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async =>
      (await _car.future).playFromSearch(query);

  Output get output => _output;
  List<QueueEntry> get entries => _entries;
  OutputState get outputState => _output.state;
  Stream<OutputState> get outputStates => _output.states;

  bool get _loaded => _output.state.index >= 0;
  int get _currentIndex => _loaded ? _output.state.index : _pendingIndex;

  QueueSnapshot snapshot() => QueueSnapshot(
        outputId: _output.id,
        entries: _entries,
        index: _currentIndex,
        position: _loaded ? _output.state.position : _pendingPosition,
      );

  /// Saves now; for when the app is about to be suspended or killed.
  void saveNow() {
    _saveTimer?.cancel();
    _savedAt = DateTime.now();
    _savedIndex = _currentIndex;
    onSnapshot?.call(snapshot());
  }

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      _savedAt = DateTime.now();
      _savedIndex = _currentIndex;
      onSnapshot?.call(snapshot());
    });
  }

  /// Shows a saved queue without playing it.
  void restore(QueueSnapshot snap) {
    _setEntries(snap.entries);
    _pendingIndex = snap.index;
    _pendingPosition = snap.position;
    _restoredFrom = snap.outputId;
    _publish(_output.state);
  }

  /// Goes back to this device when the renderer in use has gone, e.g. the
  /// phone left the home network. The queue stays where the renderer last
  /// was, paused: nothing starts playing on the phone by itself.
  Future<void> dropOutput() async {
    if (_output.isLocal) return;
    final prev = _output;
    final index = _currentIndex;
    final position = _loaded ? prev.state.position : _pendingPosition;
    final items = [for (final e in _entries) e.item];
    await _sub?.cancel();
    // It can't be reached; don't wait on it to say goodbye.
    unawaited(prev.dispose().timeout(const Duration(seconds: 3), onTimeout: () {}).catchError((_) {}));
    _output = localOutput;
    outputListenable.value = localOutput;
    _listen();
    final (entries, newIndex, skippedNow) =
        _resolve(items, index < 0 ? 0 : index, await localOutput.sinks(), local: true);
    skipped = skippedNow;
    _setEntries(entries);
    _pendingIndex = entries.isEmpty ? -1 : newIndex;
    _pendingPosition = position;
    _publish(localOutput.state);
  }

  /// Makes [out] the output and follows whatever it's already playing; if
  /// it's playing nothing we know, the current queue stays pending on it.
  Future<void> adopt(Output out) async {
    if (out.id != _output.id) {
      await _sub?.cancel();
      if (!_output.isLocal) await _output.dispose();
      _output = out;
      outputListenable.value = out;
      _listen();
    }
    final q = await out.attach(_entries);
    if (q != null) {
      _pendingIndex = -1;
      _setEntries(q);
    }
    _publish(out.state);
  }

  Future<void> _loadPending([int? index]) async {
    _restoredFrom = null;
    try {
      await _output.load(
        _entries,
        (index ?? _pendingIndex).clamp(0, _entries.length - 1),
        position: index == null ? _pendingPosition : Duration.zero,
      );
    } finally {
      _pendingIndex = -1;
    }
  }

  /// Plays [items] starting at [start], choosing for each the resource the
  /// current output can play. Items with none are left out of the queue.
  Future<void> playItems(List<DidlItem> items, int start) async {
    final (entries, index, skippedNow) =
        _resolve(items, start, await _output.sinks(), local: _output.isLocal);
    skipped = skippedNow;
    _pendingIndex = -1;
    _restoredFrom = null;
    _setEntries(entries);
    if (entries.isEmpty) {
      await _output.stop();
      return;
    }
    await _output.load(entries, index);
  }

  /// Inserts [items] right after the current track. Returns how many were
  /// added; the rest are in [skipped].
  Future<int> playNext(List<DidlItem> items) => _insertItems(_currentIndex + 1, items);

  /// Appends [items] to the queue.
  Future<int> addToQueue(List<DidlItem> items) => _insertItems(_entries.length, items);

  Future<int> _insertItems(int at, List<DidlItem> items) async {
    // Nothing queued yet: adding is the same as playing.
    if (_entries.isEmpty) {
      await playItems(items, 0);
      return _entries.length;
    }
    final (entries, _, left) = _resolve(items, 0, await _output.sinks(), local: _output.isLocal);
    skipped = left;
    if (entries.isEmpty) return 0;
    at = at.clamp(0, _entries.length);
    _setEntries([..._entries]..insertAll(at, entries));
    if (_loaded) {
      await _output.insert(at, entries);
    } else if (at <= _pendingIndex) {
      _pendingIndex += entries.length;
    }
    return entries.length;
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    _setEntries([..._entries]..removeAt(index));
    if (_loaded) {
      await _output.removeAt(index);
    } else if (index < _pendingIndex || _pendingIndex >= _entries.length) {
      _pendingIndex--;
    }
    if (_entries.isEmpty) await clearQueue();
  }

  /// Moves a queued track; the one playing stays put.
  Future<void> moveQueueItem(int from, int to) async {
    if (from == _currentIndex || from < 0 || from >= _entries.length) return;
    to = to.clamp(0, _entries.length - 1);
    final list = [..._entries];
    list.insert(to, list.removeAt(from));
    _setEntries(list);
    if (_loaded) {
      await _output.move(from, to);
    } else {
      if (from < _pendingIndex) _pendingIndex--;
      if (to <= _pendingIndex) _pendingIndex++;
    }
  }

  Future<void> clearQueue() async {
    _pendingIndex = -1;
    _restoredFrom = null;
    _setEntries(const []);
    await _output.clear();
    mediaItem.add(null);
    await super.stop();
  }

  /// Picks a resource for each item; returns the playable entries, where
  /// [start] landed among them, and the items left out: those in formats
  /// the output can't play, and, on a renderer, tracks from a paired home,
  /// which only this device can reach.
  (List<QueueEntry>, int, List<DidlItem>) _resolve(
      List<DidlItem> items, int start, List<ProtocolInfo> sinks, {required bool local}) {
    final entries = <QueueEntry>[];
    final left = <DidlItem>[];
    var index = 0;
    for (var i = 0; i < items.length; i++) {
      final res = ResourceSelector.select(items[i], sinks, preference: preference);
      if (res == null || (!local && HomeProxy.isHomeUrl(res.uri))) {
        left.add(items[i]);
        continue;
      }
      if (i <= start) index = entries.length;
      entries.add(QueueEntry(items[i], res));
    }
    return (entries, index, left);
  }

  void _setEntries(List<QueueEntry> entries) {
    _entries = entries;
    queue.add([for (final e in entries) _mediaItem(e)]);
    _saveSoon();
  }

  /// Moves playback to [next], carrying over the queue and position.
  /// Resources are chosen again, since the new output may accept
  /// different formats.
  ///
  /// When nothing is playing here, [next] is first asked what it's already
  /// playing: the queue we left on it before a restart, or something
  /// another app or phone started. Then that is followed instead.
  Future<void> switchOutput(Output next) async {
    if (next.id == _output.id) return;
    final prev = _output;
    final wasLoaded = _loaded;
    final wasPlaying = prev.state.playing;
    final index = _currentIndex;
    final position = wasLoaded ? prev.state.position : _pendingPosition;
    final items = [for (final e in _entries) e.item];

    await _sub?.cancel();
    try {
      await prev.stop();
    } on Object {
      // The old renderer may already be gone.
    }
    if (!prev.isLocal) await prev.dispose();
    _output = next;
    outputListenable.value = next;
    _listen();

    // Follow what the new output plays only if that can't replace a queue
    // the user is in the middle of.
    if (items.isEmpty || (!wasLoaded && _restoredFrom == next.id)) {
      final q = await next.attach(_entries);
      if (q != null) {
        _pendingIndex = -1;
        _setEntries(q);
        _publish(next.state);
        return;
      }
    }
    if (items.isEmpty) return;

    final (entries, newIndex, skippedNow) = _resolve(items, index, await next.sinks(), local: next.isLocal);
    skipped = skippedNow;
    _setEntries(entries);
    if (entries.isEmpty) return;
    if (wasPlaying) {
      _pendingIndex = -1;
      await next.load(entries, newIndex, position: position);
    } else {
      // Paused or not yet started: move it over, start when asked.
      _pendingIndex = newIndex;
      _pendingPosition = position;
      _publish(next.state);
    }
  }

  void _listen() {
    _sub = _output.states.listen(_publish);
  }

  void _publish(OutputState s) {
    final out = _output;
    _keepAlive?.update(
      needed: keepAliveEnabled &&
          out is RendererOutput &&
          s.error == null &&
          keepAliveNeeded(
              queueLength: _entries.length, index: s.index, tracksAhead: out.tracksAhead),
      playing: s.playing || s.buffering,
    );
    final index = s.index >= 0 ? s.index : _pendingIndex;
    final hasItem = index >= 0 && index < _entries.length;
    if (hasItem && mediaItem.value?.id != _entries[index].resource.uri.toString()) {
      mediaItem.add(_mediaItem(_entries[index], s.index >= 0 ? s.duration : null));
    }
    if (index != _savedIndex ||
        (s.playing && DateTime.now().difference(_savedAt) > const Duration(seconds: 15))) {
      _savedIndex = index;
      _saveSoon();
    }
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        s.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.skipToQueueItem,
        MediaAction.playFromMediaId,
        MediaAction.playFromSearch,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: s.error != null
          ? AudioProcessingState.error
          : s.completed
              ? AudioProcessingState.completed
              : s.buffering
                  ? AudioProcessingState.buffering
                  : s.index >= 0
                      ? AudioProcessingState.ready
                      : AudioProcessingState.idle,
      playing: s.playing,
      updatePosition: s.index >= 0 ? s.position : _pendingPosition,
      queueIndex: hasItem ? index : null,
      errorMessage: s.error,
    ));
  }

  MediaItem _mediaItem(QueueEntry e, [Duration? duration]) {
    final i = e.item;
    final composer = i.composer;
    return MediaItem(
      id: e.resource.uri.toString(),
      title: i.title,
      artist: i.performer,
      album: i.album,
      artUri: i.albumArt,
      duration: duration ?? e.resource.duration ?? i.duration,
      displaySubtitle: composer != null ? '$composer · ${i.performer ?? ''}' : i.performer,
      extras: {'format': e.resource.formatLabel, 'composer': ?composer},
    );
  }

  @override
  Future<void> play() async {
    if (!_loaded && _entries.isNotEmpty) return _loadPending();
    await _output.play();
  }

  @override
  Future<void> pause() async {
    await _output.pause();
    _saveSoon();
  }
  @override
  Future<void> stop() async {
    await _output.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_loaded) return _output.seek(position);
    _pendingPosition = position;
    _publish(_output.state);
  }

  /// True while a queue is shown but not loaded into the output.
  bool get hasPendingQueue => !_loaded && _entries.isNotEmpty;

  @override
  Future<void> skipToQueueItem(int index) =>
      _loaded ? _output.skipTo(index) : _loadPending(index);

  @override
  Future<void> skipToNext() async {
    final i = _currentIndex;
    if (i + 1 < _entries.length) await skipToQueueItem(i + 1);
  }

  @override
  Future<void> skipToPrevious() async {
    final s = _output.state;
    if (!_loaded) {
      if (_pendingIndex > 0) await skipToQueueItem(_pendingIndex - 1);
    } else if (s.position > const Duration(seconds: 3) || s.index <= 0) {
      await _output.seek(Duration.zero);
    } else {
      await _output.skipTo(s.index - 1);
    }
  }
}
