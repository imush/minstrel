import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:path_provider/path_provider.dart';

/// Homes paired through minstrel-launchpad, whose media servers are listed
/// alongside the ones on the local network.
class Homes extends ChangeNotifier {
  final HomeProxy proxy;
  final DeviceRegistry _registry;
  final File _file;
  List<Home> _homes;

  Homes._(this.proxy, this._registry, this._file, this._homes) {
    proxy.changes.listen((_) => notifyListeners());
  }

  static Future<Homes> start(DeviceRegistry registry) async {
    final proxy = HomeProxy();
    await proxy.start();
    final file = File('${(await getApplicationSupportDirectory()).path}/homes.json');
    var homes = <Home>[];
    try {
      if (await file.exists()) {
        homes = [
          for (final j in (jsonDecode(await file.readAsString()) as List).cast<Map<String, dynamic>>())
            Home.fromJson(j),
        ];
      }
    } on Object {
      // Unreadable: start without homes rather than not at all.
    }
    for (final h in homes) {
      proxy.add(h);
    }
    final service = Homes._(proxy, registry, file, homes);
    unawaited(service.refreshAll());
    return service;
  }

  List<Home> get homes => List.unmodifiable(_homes);

  HomeStatus status(Home home) => proxy.status(home.id);

  /// Reconnects to every home and reloads its server list.
  Future<void> refreshAll() => Future.wait(_homes.map(refresh));

  Future<void> refresh(Home home) async {
    try {
      final info = await proxy.info(home.id);
      // Follow changes made on the launchpad's console: its addresses, and
      // its name unless this device named the home itself.
      var updated = home;
      if (info.addresses.isNotEmpty && !listEquals(info.addresses, home.addresses)) {
        updated = updated.copyWith(addresses: info.addresses);
      }
      if (!home.renamed && info.name.isNotEmpty && info.name != home.name) {
        updated = updated.copyWith(name: info.name);
      }
      if (!identical(updated, home)) await _replace(updated);
      await _registry.setHomeServers(home.id, updated.name, [for (final s in info.servers) s.description]);
    } on Object {
      // The status shows why; servers already listed stay until it's back.
    }
    notifyListeners();
  }

  /// Names [home] on this device. An empty name goes back to the one set
  /// on the launchpad.
  Future<void> rename(Home home, String name) async {
    final trimmed = name.trim();
    await _replace(trimmed.isEmpty
        ? home.copyWith(renamed: false)
        : home.copyWith(name: trimmed, renamed: true));
    notifyListeners();
    await refresh(_homes.firstWhere((h) => h.id == home.id));
  }

  Future<void> _replace(Home home) async {
    _homes = [for (final h in _homes) h.id == home.id ? home : h];
    await _save();
    proxy.update(home);
  }

  Future<Home> pair(PairingInvitation invitation, {required String deviceName}) async {
    final home = await pairWithLaunchpad(invitation, deviceName: deviceName);
    _homes = [..._homes.where((h) => h.id != home.id), home];
    await _save();
    proxy.add(home);
    notifyListeners();
    await refresh(home);
    return home;
  }

  /// Forgets a home on this device. (It stays listed on the launchpad until
  /// revoked there.)
  Future<void> remove(Home home) async {
    _homes = _homes.where((h) => h.id != home.id).toList();
    await _save();
    proxy.remove(home.id);
    _registry.removeHome(home.id);
    notifyListeners();
  }

  Future<void> _save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final h in _homes) h.toJson()]));
    await tmp.rename(_file.path);
  }

  /// A default name for this device on the launchpad's device list.
  static String get deviceName {
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isAndroid) return 'Android phone';
    return Platform.localHostname;
  }
}
