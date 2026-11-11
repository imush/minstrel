import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cache/cache_fetcher.dart';
import 'cache/cache_store.dart';
import 'cache/device_storage.dart';
import 'car/car_library.dart';
import 'car/car_services.dart';
import 'car/carplay.dart';
import 'homes.dart';
import 'playback/audio_handler.dart';
import 'playback/output.dart';
import 'playback/relay.dart';
import 'playback/renderer_output.dart';

/// App-wide singletons, created once in main().
class AppServices {
  static late final AppServices instance;

  final http.Client http_;
  final DeviceRegistry registry;
  final MinstrelAudioHandler player;
  final SharedPreferences prefs;
  final Homes homes;
  final CarLibrary car;

  /// Permission for players on the network the phone is on to fetch home
  /// tracks through it.
  final Relay relay;

  /// Music kept on this device, and the fetch that fills it. Set up in
  /// [_startCache], which needs the application support directory.
  late final CacheStore cache;
  late final CacheFetcher cacheFetcher;

  AppServices._(this.http_, this.registry, this.player, this.prefs, this.homes, this.car)
      : relay = Relay(homes.proxy);

  static const _manualKey = 'manualDevices';
  static const _rememberedKey = 'rememberedDevices';
  static const _qualityKey = 'quality';
  static const _compressionKey = 'awayCompression';
  static const _cacheOnKey = 'cacheEnabled';
  static const _cacheBudgetKey = 'cacheBudget';
  static const _multicast = MethodChannel('org.minstrelplayer/multicast');

  static Future<void> init() async {
    final client = http.Client();
    // Music playback: keeps playing in the background and with the screen
    // locked, and shows Now Playing controls.
    await (await AudioSession.instance).configure(const AudioSessionConfiguration.music());
    final player = await AudioService.init(
      builder: MinstrelAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'org.minstrelplayer.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationIcon: 'drawable/ic_stat_minstrel',
        androidStopForegroundOnPause: false,
        // Android Auto: searchable, lists with artwork.
        androidBrowsableRootExtras: {
          'android.media.browse.SEARCH_SUPPORTED': true,
          AndroidContentStyle.supportedKey: true,
          AndroidContentStyle.browsableHintKey: AndroidContentStyle.listItemHintValue,
          AndroidContentStyle.playableHintKey: AndroidContentStyle.listItemHintValue,
        },
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    player.preference = QualityPreference.values
            .where((q) => q.name == prefs.getString(_qualityKey))
            .firstOrNull ??
        QualityPreference.best;
    final registry = DeviceRegistry(client)
      ..remember([for (final l in prefs.getStringList(_rememberedKey) ?? const <String>[]) Uri.parse(l)])
      ..onRemembered = (locations) =>
          unawaited(prefs.setStringList(_rememberedKey, [for (final l in locations) l.toString()]));
    final car = CarLibrary(RegistrySource(registry), PhonePlayer(player), PrefsHistory(prefs));
    player.attachCar(car);
    instance = AppServices._(client, registry, player, prefs, await Homes.start(registry), car);
    instance.homes.proxy.compression = prefs.getString(_compressionKey);
    player.relay = instance.relay;
    if (Platform.isIOS) unawaited(CarPlayBridge(car).start());
    // Coming back to the app may mean a new network: home Wi-Fi, cellular.
    AppLifecycleListener(onResume: () {
      unawaited(instance.registry.refresh());
      // The network may have changed meanwhile: on arriving home, use the
      // home address rather than going out and back in.
      instance.homes.proxy.recheck();
      // Permission to relay belongs to one network; coming back may be on
      // another.
      unawaited(instance.relay.recheck());
      unawaited(instance.homes.refreshAll());
    });
    await instance._startCache();
    // The queue first: a car may be asking for it while discovery waits
    // on servers that are out of reach.
    await instance._restoreQueue();
    instance._watchOutput();
    await instance._startDiscovery();
  }

  /// Sets up the offline cache and starts filling it.
  Future<void> _startCache() async {
    // Application Support, not a caches directory: both platforms empty
    // those under pressure, which would throw away pinned music. The name
    // is also in the Android backup rules, which leave it out of backups.
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/music-cache');
    cache = CacheStore(dir)..enabled = prefs.getBool(_cacheOnKey) ?? true;
    final saved = prefs.getInt(_cacheBudgetKey);
    // A tenth of the free space, the first time the app is run here.
    cache.budget = saved ?? CacheStore.defaultBudget(await DeviceStorage.space());
    if (saved == null) await prefs.setInt(_cacheBudgetKey, cache.budget);
    await cache.load();
    await DeviceStorage.excludeFromBackup(dir.path);

    cacheFetcher = CacheFetcher(cache, homes.proxy);
    await cacheFetcher.load();
    player.onPlayed = (e) => cacheFetcher.notePlayed(e.item, e.resource);
    player.localOutput.sourceFor = _playFrom;
    player.copyForRenderer = _copyForRenderer;
    homes.proxy.localCopies = (name) {
      final held = cache.byFile(name);
      return held == null
          ? null
          : LocalCopy(cache.fileOf(held), held.resource.mimeType,
              source: held.resource.uri);
    };
    // Arriving home is what gives the fetch its chance.
    homes.proxy.changes.listen((_) => unawaited(cacheFetcher.pump()));
    AppLifecycleListener(onResume: () => unawaited(cacheFetcher.pump()));
    unawaited(cacheFetcher.pump());
  }

  /// Where to fetch a queued track's bytes on this device.
  ///
  /// The server's own copy whenever it can be reached on this network: that
  /// is the full-quality one, and the fetcher replaces anything lesser the
  /// cache is holding. Away from it, a cached copy stands in when it is at
  /// least as good as what the server would send, and whatever its quality
  /// when the server can't be reached at all.
  Uri _playFrom(QueueEntry e) {
    final uri = e.resource.uri;
    final key = CacheStore.keyFor(uri);
    if (key == null) return uri; // a relay URL, or already a cached file
    final (onThisNetwork: near, reachable: up) = _sourceState(uri);
    if (near && up) return uri;
    final hit = cache.standIn(key, e.resource,
        homeReachable: up,
        sinks: Platform.isAndroid ? LocalSinks.android : LocalSinks.apple);
    if (hit == null) return uri;
    cache.touch(key);
    return cache.fileOf(hit).uri;
  }

  /// Where a track's server is: on this network, and answering at all.
  ///
  /// A server behind a launchpad is judged by the launchpad's connection. A
  /// server named directly is judged by whether discovery can still see it,
  /// which is the only way to tell a server that is off — or a network we
  /// have left — from one that is simply slow.
  ({bool onThisNetwork, bool reachable}) _sourceState(Uri uri) {
    if (HomeProxy.isHomeUrl(uri)) {
      final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final status = homes.proxy.status(seg.length > 1 ? seg[1] : '');
      final up = status.state == HomeState.connected;
      return (onThisNetwork: up && status.atHome, reachable: up);
    }
    final here = registry.servers
        .any((s) => s.device.location.authority == uri.authority);
    return (onThisNetwork: here, reachable: here);
  }

  /// What to hand a renderer for a track whose server it cannot reach:
  /// a copy held here, served through the relay.
  ///
  /// Only when the server is out of our reach too. While it answers, the
  /// renderer is sent to it — directly on this network, or relayed from
  /// home as before — because that is the full-quality copy.
  DidlResource? _copyForRenderer(DidlResource wanted, List<ProtocolInfo> sinks) {
    final key = CacheStore.keyFor(wanted.uri);
    if (key == null) return null;
    final (onThisNetwork: near, reachable: up) = _sourceState(wanted.uri);
    if (near && up) return null;
    final hit = cache.standIn(key, wanted, homeReachable: up, sinks: sinks);
    if (hit == null) return null;
    // Needs the relay open; without permission this falls back to the home
    // route, which asks for it.
    final via = homes.proxy.relayForCopy(hit.file);
    if (via == null) return null;
    cache.touch(key);
    return hit.resource.withUri(via);
  }

  /// Keeps [items] on this device whether or not they are played, for a
  /// flight or a drive out of signal.
  int download(Iterable<DidlItem> items, {bool pin = false}) =>
      cacheFetcher.request(items, pin: pin);

  /// Whether to keep music on this device at all.  /// Whether to keep music on this device at all. Turning it off empties
  /// the cache, so the switch asks first.
  Future<void> setCacheEnabled(bool on) async {
    cache.enabled = on;
    await prefs.setBool(_cacheOnKey, on);
    if (on) {
      unawaited(cacheFetcher.pump());
    } else {
      await cacheFetcher.forget();
      await cache.clear();
    }
  }

  Future<void> setCacheBudget(int bytes) async {
    cache.budget = bytes;
    await prefs.setInt(_cacheBudgetKey, bytes);
    await cache.trim();
    unawaited(cacheFetcher.pump());
  }

  /// Brings back the queue from the last run. On a renderer, it reconnects
  /// once the renderer is found and follows whatever it's playing.
  Future<void> _restoreQueue() async {
    final file = File('${(await getApplicationSupportDirectory()).path}/queue.json');
    player.onSnapshot = (snap) {
      file.writeAsString(snap.encode()).catchError((Object _) => file);
    };
    final QueueSnapshot? snap;
    try {
      snap = await file.exists() ? QueueSnapshot.decode(await file.readAsString()) : null;
    } on Object {
      return;
    }
    // iOS may kill a suspended app without warning, so save on the way out.
    AppLifecycleListener(onHide: player.saveNow, onDetach: player.saveNow);
    if (snap == null || snap.entries.isEmpty) return;
    player.restore(_rehomed(snap));
    if (snap.outputId != 'local') unawaited(_reconnect(snap.outputId));
  }

  /// Tracks from a paired home go through the local proxy, whose port may
  /// differ from the last run.
  QueueSnapshot _rehomed(QueueSnapshot snap) => QueueSnapshot(
        outputId: snap.outputId,
        index: snap.index,
        position: snap.position,
        entries: [
          for (final e in snap.entries) QueueEntry(e.item, e.resource.withUri(homes.proxy.rehome(e.resource.uri))),
        ],
      );

  /// Leaves a renderer that discovery has dropped (the phone left home, or
  /// the player was switched off), after a few seconds' grace in case it is
  /// only being found again on a new network.
  void _watchOutput() {
    Timer? grace;
    registry.changes.listen((_) {
      // Discovery notices the interfaces moving before anything else does.
      unawaited(relay.recheck());
      final out = player.output;
      if (out.isLocal || registry.renderer(out.id) != null) {
        grace?.cancel();
        grace = null;
        return;
      }
      grace ??= Timer(const Duration(seconds: 4), () {
        grace = null;
        if (player.output.id == out.id && registry.renderer(out.id) == null) unawaited(player.dropOutput());
      });
    });
  }

  Future<void> _reconnect(String udn, {Duration within = const Duration(minutes: 1)}) async {
    var renderer = registry.renderer(udn);
    if (renderer == null) {
      final found = Completer<void>();
      final sub = registry.changes.listen((_) {
        if (registry.renderer(udn) != null && !found.isCompleted) found.complete();
      });
      await found.future.timeout(within, onTimeout: () {});
      await sub.cancel();
      renderer = registry.renderer(udn);
    }
    // Give up quietly if the renderer isn't around, or if the user has
    // started something else meanwhile.
    if (renderer == null || !player.output.isLocal || !player.hasPendingQueue) return;
    final out = outputFor(udn);
    if (out != null) await player.adopt(out);
  }

  Future<void> _startDiscovery() async {
    if (Platform.isAndroid) {
      // Android drops multicast packets unless an app holds a MulticastLock.
      try {
        await _multicast.invokeMethod('acquire');
      } on PlatformException {
        // Search responses are unicast and still arrive without it.
      }
    }
    await registry.start();
    for (final url in manualDevices) {
      try {
        await registry.addManual(Uri.parse(url));
      } on Object {
        // Unreachable right now (VPN down, server off); kept for later.
      }
    }
  }

  Future<void> setQualityPreference(QualityPreference q) async {
    player.preference = q;
    await prefs.setString(_qualityKey, q.name);
  }

  /// The compression to ask launchpads for when playing from home away
  /// from it (`aac-192` and so on), or null for the original files.
  String? get compression => homes.proxy.compression;

  Future<void> setCompression(String? profile) async {
    homes.proxy.compression = profile;
    if (profile == null) {
      await prefs.remove(_compressionKey);
    } else {
      await prefs.setString(_compressionKey, profile);
    }
  }

  List<String> get manualDevices => prefs.getStringList(_manualKey) ?? const [];

  Future<void> addManualDevice(Uri location) async {
    await registry.addManual(location);
    final list = {...manualDevices, location.toString()}.toList();
    await prefs.setStringList(_manualKey, list);
  }

  Future<void> removeManualDevice(Uri location) async {
    registry.removeManual(location);
    await prefs.setStringList(
        _manualKey, manualDevices.where((u) => u != location.toString()).toList());
  }

  /// Output for a given id: `local` or a renderer UDN.
  Output? outputFor(String id) {
    if (id == 'local') return player.localOutput;
    if (id == player.output.id) return player.output;
    final r = registry.renderer(id);
    return r == null ? null : RendererOutput(r);
  }
}
