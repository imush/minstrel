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
import 'relay.dart';
import 'renderer_output.dart';
import 'system_volume.dart';

/// The single place playback is controlled from: the app UI, the lock
/// screen and notification, headset buttons and (later) Android Auto and
/// CarPlay. It owns the queue and drives whichever [Output] is active.
class MinstrelAudioHandler extends BaseAudioHandler with SeekHandler {
  final LocalOutput localOutput = LocalOutput();
  late Output _output = localOutput;

  /// Notifies when playback moves to a different output.
  late final ValueNotifier<Output> outputListenable = ValueNotifier(_output);
  StreamSubscription<OutputState>? _sub;

  /// iOS only: keeps the lock screen controls and the app running while a
  /// renderer plays.
  final KeepAlive? _keepAlive = Platform.isIOS ? KeepAlive() : null;

  List<QueueEntry> _entries = const [];
  QualityPreference preference = QualityPreference.best;

  /// Items from the last request in no format the output can play.
  List<DidlItem> skipped = const [];

  /// Items from the last request that were left out because they live in a
  /// paired home and the output is a renderer, which can only fetch them if
  /// this phone passes them on — and that isn't allowed on this network.
  /// Asking [relay] and queueing again is what clears this.
  List<DidlItem> needRelay = const [];

  /// Set once the home proxy exists. Without it, or without the user's
  /// permission for the network the phone is on, home tracks can't go to a
  /// renderer at all.
  Relay? relay;

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
      if (parentMediaId == AudioService.browsableRootId) {
        _republish();
        return car.roots().map(carMediaItem).toList();
      }
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

  /// Sends the queue, track and state to the media session again. Android
  /// may have recreated the playback service since they last changed, and a
  /// new session starts out empty: the car would show nothing playing. The
  /// car asks for the top of its menus whenever it connects.
  void _republish() {
    queue.add(queue.value);
    if (mediaItem.value case final item?) mediaItem.add(item);
    _publish(_output.state);
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
    final r = _resolve(items, index < 0 ? 0 : index, await localOutput.sinks(), local: true);
    skipped = r.unplayable;
    needRelay = r.needRelay;
    _setEntries(r.entries);
    _pendingIndex = r.entries.isEmpty ? -1 : r.index;
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
    final r = _resolve(items, start, await _output.sinks(), local: _output.isLocal);
    skipped = r.unplayable;
    needRelay = r.needRelay;
    _pendingIndex = -1;
    _restoredFrom = null;
    _setEntries(r.entries);
    if (r.entries.isEmpty) {
      await _output.stop();
      return;
    }
    await _output.load(r.entries, r.index);
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
    final r = _resolve(items, 0, await _output.sinks(), local: _output.isLocal);
    skipped = r.unplayable;
    needRelay = r.needRelay;
    if (r.entries.isEmpty) return 0;
    at = at.clamp(0, _entries.length);
    _setEntries([..._entries]..insertAll(at, r.entries));
    if (_loaded) {
      await _output.insert(at, r.entries);
    } else if (at <= _pendingIndex) {
      _pendingIndex += r.entries.length;
    }
    return r.entries.length;
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

  /// Picks a resource for each item, and for a renderer a URL it can
  /// actually fetch.
  _Resolved _resolve(
      List<DidlItem> items, int start, List<ProtocolInfo> sinks, {required bool local}) {
    final entries = <QueueEntry>[];
    final unplayable = <DidlItem>[];
    final needRelay = <DidlItem>[];
    var index = 0;
    for (var i = 0; i < items.length; i++) {
      final res = ResourceSelector.select(items[i], sinks, preference: preference);
      if (res == null) {
        unplayable.add(items[i]);
        continue;
      }
      var chosen = res;
      if (!local && HomeProxy.isHomeUrl(res.uri)) {
        // A home URL is loopback: it means this phone, so to a renderer it
        // would mean the renderer itself. It needs one this phone serves on
        // the local network, which takes the user's permission.
        final via = relay?.urlFor(res.uri);
        if (via == null) {
          needRelay.add(items[i]);
          continue;
        }
        chosen = res.withUri(via);
      }
      if (i <= start) index = entries.length;
      entries.add(QueueEntry(items[i], chosen));
    }
    return _Resolved(entries, index, unplayable, needRelay);
  }

  void _setEntries(List<QueueEntry> entries) {
    _entries = entries;
    // The relay serves the queue and nothing else, so a URL that leaks off
    // this network is worth only what is playing.
    relay?.setQueue([for (final e in entries) e.resource.uri]);
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

    final r = _resolve(items, index, await next.sinks(), local: next.isLocal);
    skipped = r.unplayable;
    needRelay = r.needRelay;
    _setEntries(r.entries);
    if (r.entries.isEmpty) return;
    if (wasPlaying) {
      _pendingIndex = -1;
      await next.load(r.entries, r.index, position: position);
    } else {
      // Paused or not yet started: move it over, start when asked.
      _pendingIndex = r.index;
      _pendingPosition = position;
      _publish(next.state);
    }
  }

  void _listen() {
    _sub = _output.states.listen(_publish);
    _followVolume();
  }

  VoidCallback? _unfollowVolume;

  /// While a renderer plays, the side buttons change its volume, not the
  /// phone's.
  void _followVolume() {
    _unfollowVolume?.call();
    _unfollowVolume = null;
    if (Platform.isIOS) {
      unawaited(_followVolumeIos(_output));
    } else if (Platform.isAndroid) {
      _followVolumeAndroid(_output);
    }
  }

  /// Android has a remote volume for this: the system's volume panel and
  /// the side buttons then show and change the renderer's volume.
  void _followVolumeAndroid(Output out) {
    if (out is! RendererOutput) {
      androidPlaybackInfo.add(LocalAndroidPlaybackInfo());
      return;
    }
    void update() {
      final v = out.volume.value;
      androidPlaybackInfo.add(v == null
          ? LocalAndroidPlaybackInfo()
          : RemoteAndroidPlaybackInfo(
              volumeControlType: AndroidVolumeControlType.absolute, maxVolume: 100, volume: v));
    }

    out.volume.addListener(update);
    _unfollowVolume = () => out.volume.removeListener(update);
    update();
  }

  /// The phone's volume from before a renderer took over, put back when
  /// playback returns to the phone.
  double? _phoneVolume;

  /// iOS has no remote volume. Instead, while a renderer plays, the phone's
  /// volume stands for the renderer's, as in mConnect and foobar2000: the
  /// side buttons, Control Center and the lock screen move it, and Minstrel
  /// passes it on; changes on the renderer's side move it back. All the
  /// phone plays then is silence (see [KeepAlive]), so its own level
  /// doesn't matter.
  Future<void> _followVolumeIos(Output out) async {
    if (out is! RendererOutput) {
      final v = _phoneVolume;
      _phoneVolume = null;
      if (v != null) await SystemVolume.set(v);
      return;
    }
    _phoneVolume ??= await SystemVolume.get();
    if (_output != out) return;
    var fromPhone = false;
    void toPhone() {
      final v = out.volume.value;
      if (v != null && !fromPhone) unawaited(SystemVolume.set(RendererOutput.volumeToSlider(v)));
    }

    final sub = SystemVolume.changes.listen((v) {
      fromPhone = true;
      out.setVolume(RendererOutput.sliderToVolume(v));
      fromPhone = false;
    });
    out.volume.addListener(toPhone);
    _unfollowVolume = () {
      out.volume.removeListener(toPhone);
      unawaited(sub.cancel());
    };
    toPhone();
  }

  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) async {
    if (_output case final RendererOutput out) out.setVolume(volumeIndex);
  }

  @override
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) async {
    if (_output case final RendererOutput out) out.stepVolume(direction.index);
  }

  void _publish(OutputState s) {
    final out = _output;
    _keepAlive?.update(
      active: out is RendererOutput && s.error == null && s.index >= 0,
      playing: s.playing || s.buffering,
    );
    final index = s.index >= 0 ? s.index : _pendingIndex;
    final hasItem = index >= 0 && index < _entries.length;
    // Players learn a track's length only after it starts, and may report
    // zero until then (ExoPlayer at a gapless switch, renderers before the
    // next track's first poll): zero means not known yet.
    final reported = s.index >= 0 && s.duration != null && s.duration! > Duration.zero ? s.duration : null;
    if (hasItem && mediaItem.value?.id != _entries[index].resource.uri.toString()) {
      mediaItem.add(_mediaItem(_entries[index], reported));
    } else if (hasItem && reported != null && mediaItem.value?.duration != reported) {
      mediaItem.add(mediaItem.value!.copyWith(duration: reported));
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

  static Duration? _known(Duration? d) => d != null && d > Duration.zero ? d : null;

  MediaItem _mediaItem(QueueEntry e, [Duration? duration]) {
    final i = e.item;
    final composer = i.composer;
    return MediaItem(
      id: e.resource.uri.toString(),
      title: i.title,
      artist: i.performer,
      album: i.album,
      artUri: i.albumArt,
      duration: duration ?? _known(e.resource.duration) ?? _known(i.duration),
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

/// What [MinstrelAudioHandler._resolve] made of a request: the playable
/// entries, where the requested start landed among them, and the two
/// separate reasons an item didn't make it.
class _Resolved {
  final List<QueueEntry> entries;
  final int index;
  final List<DidlItem> unplayable;
  final List<DidlItem> needRelay;

  const _Resolved(this.entries, this.index, this.unplayable, this.needRelay);
}
