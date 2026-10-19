import 'dart:async';

import 'package:http/http.dart' as http;

import 'device.dart';
import 'renderer.dart';
import 'services.dart';
import 'soap.dart';
import 'ssdp.dart';

class MediaServer {
  final UpnpDevice device;
  final ContentDirectory contentDirectory;

  /// The home this server is reached through, for one behind a
  /// minstrel-launchpad; null on the local network.
  final String? via;
  final String? homeId;

  MediaServer(this.device, this.contentDirectory, {this.via, this.homeId});

  String get udn => device.udn;
  String get name => device.friendlyName;
}

/// Keeps the current set of media servers and renderers, from SSDP on the
/// LAN plus any added by URL.
class DeviceRegistry {
  final http.Client _http;
  final SoapClient _soap;
  final SsdpClient _ssdp = SsdpClient();
  StreamSubscription<SsdpMessage>? _sub;

  final _servers = <String, MediaServer>{};
  final _remote = <String, MediaServer>{}; // by UDN, behind a launchpad
  final _renderers = <String, MediaRenderer>{};
  final _pending = <Uri>{};
  final _manual = <Uri>{};
  final _changes = StreamController<void>.broadcast();

  DeviceRegistry(this._http) : _soap = SoapClient(_http);

  Stream<void> get changes => _changes.stream;
  /// Servers on the LAN, then those of paired homes. A home's server that is
  /// also on the LAN (when the phone is at home) is listed once, directly.
  List<MediaServer> get servers => [
        ..._servers.values,
        ..._remote.values.where((r) => !_servers.containsKey(r.udn)),
      ]..sort((a, b) => a.name.compareTo(b.name));
  List<MediaRenderer> get renderers =>
      _renderers.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  /// The OS blocked discovery; on Apple platforms the user must allow
  /// Local Network access in Settings.
  bool get localNetworkDenied => _ssdp.localNetworkDenied;

  MediaServer? server(String udn) => _servers[udn] ?? _remote[udn];

  /// Replaces the servers of home [homeId] with those at [descriptions].
  Future<void> setHomeServers(String homeId, String homeName, List<Uri> descriptions) async {
    final found = <String, MediaServer>{};
    await Future.wait(descriptions.map((location) async {
      try {
        for (final d in await UpnpDevice.fetch(_http, location)) {
          final cd = d.isMediaServer ? d.service('ContentDirectory') : null;
          if (cd != null) {
            found[d.udn] = MediaServer(d, ContentDirectory(_soap, cd), via: homeName, homeId: homeId);
          }
        }
      } on Object {
        // Listed by the launchpad but not answering; left out until it does.
      }
    }));
    _remote.removeWhere((_, s) => s.homeId == homeId);
    _remote.addAll(found);
    _changes.add(null);
  }

  /// The servers reached through home [homeId], including any hidden by
  /// the same server on the LAN.
  List<MediaServer> homeServers(String homeId) =>
      _remote.values.where((s) => s.homeId == homeId).toList();

  void removeHome(String homeId) {
    _remote.removeWhere((_, s) => s.homeId == homeId);
    _changes.add(null);
  }
  MediaRenderer? renderer(String udn) => _renderers[udn];

  Future<void> start() async {
    await _ssdp.start();
    _sub = _ssdp.messages.listen(_onSsdp);
    await refresh();
  }

  /// Searches the LAN again, re-reads manually added devices, and drops
  /// devices found earlier that no longer answer: after leaving the home
  /// network they never say goodbye.
  Future<void> refresh() async {
    await _ssdp.search();
    for (final m in _manual) {
      unawaited(_load(m));
    }
    await _dropGone();
  }

  Future<void> _dropGone() async {
    final locations = {
      for (final s in _servers.values) s.device.location,
      for (final r in _renderers.values) r.device.location,
    }..removeAll(_manual);
    final gone = <Uri>{};
    await Future.wait(locations.map((l) async {
      try {
        // Any answer will do; some devices refuse HEAD but are there.
        await _http.head(l).timeout(const Duration(seconds: 3));
      } on Object {
        gone.add(l);
      }
    }));
    if (gone.isEmpty) return;
    _servers.removeWhere((_, s) => gone.contains(s.device.location));
    _renderers.removeWhere((_, r) => gone.contains(r.device.location));
    _changes.add(null);
  }

  /// Adds a device by its description URL, for servers reached over a VPN
  /// where multicast discovery can't see them.
  Future<List<UpnpDevice>> addManual(Uri location) async {
    _manual.add(location);
    return _load(location, rethrowErrors: true);
  }

  void removeManual(Uri location) {
    _manual.remove(location);
    _servers.removeWhere((_, s) => s.device.location == location);
    _renderers.removeWhere((_, r) => r.device.location == location);
    _changes.add(null);
  }

  void _onSsdp(SsdpMessage m) {
    if (m.isByeBye) {
      final udn = m.udn;
      if (udn == null) return;
      final removed = _servers.remove(udn) != null;
      final before = _renderers.length;
      _renderers.removeWhere((_, r) => r.udns.contains(udn));
      if (removed || _renderers.length != before) _changes.add(null);
      return;
    }
    final t = m.target ?? '';
    if (!t.contains('MediaServer') &&
        !t.contains('MediaRenderer') &&
        !t.contains('av-openhome-org')) {
      return;
    }
    final loc = m.location;
    if (loc == null) return;
    final udn = m.udn;
    if (udn != null && _known(udn)) return;
    unawaited(_load(loc));
  }

  bool _known(String udn) =>
      _servers.containsKey(udn) ||
      _renderers.values.any((r) => r.udns.contains(udn));

  Future<List<UpnpDevice>> _load(Uri location, {bool rethrowErrors = false}) async {
    if (!_pending.add(location)) return const [];
    try {
      final devices = await UpnpDevice.fetch(_http, location);
      var changed = false;
      for (final d in devices) {
        if (d.isMediaServer) {
          final cd = d.service('ContentDirectory');
          if (cd != null) {
            _servers[d.udn] = MediaServer(d, ContentDirectory(_soap, cd));
            changed = true;
          }
        }
      }
      // A renderer's AVTransport and OpenHome services may sit on separate
      // devices within one description (root and embedded); treat each
      // document as one physical renderer.
      final renderer = MediaRenderer.fromDevices(devices, _soap, _http);
      if (renderer != null) {
        _renderers[renderer.udn] = renderer;
        changed = true;
      }
      if (changed) _changes.add(null);
      return devices;
    } on Object {
      if (rethrowErrors) rethrow;
      return const [];
    } finally {
      _pending.remove(location);
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _ssdp.dispose();
    await _changes.close();
  }
}
