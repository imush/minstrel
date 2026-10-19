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

import 'car/car_library.dart';
import 'car/car_services.dart';
import 'car/carplay.dart';
import 'homes.dart';
import 'playback/audio_handler.dart';
import 'playback/output.dart';
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

  AppServices._(this.http_, this.registry, this.player, this.prefs, this.homes, this.car);

  static const _manualKey = 'manualDevices';
  static const _qualityKey = 'quality';
  static const _keepAliveKey = 'iosKeepAlive';
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
    player.keepAliveEnabled = prefs.getBool(_keepAliveKey) ?? true;
    final registry = DeviceRegistry(client);
    final car = CarLibrary(RegistrySource(registry), PhonePlayer(player), PrefsHistory(prefs));
    player.attachCar(car);
    instance = AppServices._(client, registry, player, prefs, await Homes.start(registry), car);
    if (Platform.isIOS) unawaited(CarPlayBridge(car).start());
    // Coming back to the app may mean a new network: home Wi-Fi, cellular.
    AppLifecycleListener(onResume: () {
      unawaited(instance.registry.refresh());
      // The network may have changed meanwhile: on arriving home, use the
      // home address rather than going out and back in.
      instance.homes.proxy.recheck();
      unawaited(instance.homes.refreshAll());
    });
    // The queue first: a car may be asking for it while discovery waits
    // on servers that are out of reach.
    await instance._restoreQueue();
    await instance._startDiscovery();
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

  Future<void> setKeepAlive(bool on) async {
    player.keepAliveEnabled = on;
    await prefs.setBool(_keepAliveKey, on);
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
