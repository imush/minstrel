import 'dart:convert';

import 'package:http/http.dart' as http;

import 'avtransport_queue.dart';
import 'device.dart';
import 'openhome.dart';
import 'protocol_info.dart';
import 'renderer_held_queue.dart';
import 'renderer_queue.dart';
import 'services.dart';
import 'soap.dart';

/// How a renderer is driven, best first.
enum QueueStrategy {
  /// OpenHome Playlist: the open standard for renderer-held queues.
  openHome,

  /// A vendor playlist service driven through AVTransport.
  playlistExtension,

  /// Plain AVTransport: the phone holds the queue and hands over one track
  /// at a time.
  avTransport,
}

/// A renderer: the AVTransport and/or OpenHome services found in one
/// device description, whether on the same device or split between root
/// and embedded devices.
class MediaRenderer {
  final UpnpDevice device;
  final List<UpnpDevice> parts;
  final AVTransport? transport;
  final RenderingControl? renderingControl;
  final ConnectionManager? connectionManager;
  final OhPlaylist? ohPlaylist;
  final OhTime? ohTime;
  final OhProduct? ohProduct;
  final OhVolume? ohVolume;
  final PlaylistExtension? playlistExtension;
  final http.Client _http;

  List<ProtocolInfo>? _sinks;
  bool? _supportsSetNext;

  MediaRenderer._(
    this.device,
    this.parts,
    this._http, {
    this.transport,
    this.renderingControl,
    this.connectionManager,
    this.ohPlaylist,
    this.ohTime,
    this.ohProduct,
    this.ohVolume,
    this.playlistExtension,
  });

  /// Builds a renderer from the devices of one description document, or
  /// returns null if none of them can play.
  static MediaRenderer? fromDevices(List<UpnpDevice> devices, SoapClient soap, http.Client client) {
    UpnpService? find(bool Function(String type) match) {
      for (final d in devices) {
        for (final s in d.services) {
          if (match(s.serviceType)) return s;
        }
      }
      return null;
    }

    bool oh(String type, String name) => type.startsWith('urn:av-openhome-org:service:$name:');
    bool upnp(String type, String name) => type.startsWith('urn:schemas-upnp-org:service:$name:');

    final avt = find((t) => upnp(t, 'AVTransport'));
    final playlist = find((t) => oh(t, 'Playlist'));
    if (avt == null && playlist == null) return null;

    // Name the renderer after its MediaRenderer device when there is one;
    // OpenHome products sometimes carry a room-prefixed name.
    final main = devices.where((d) => d.isMediaRenderer).firstOrNull ??
        devices.where((d) => d.services.any((s) => oh(s.serviceType, 'Product'))).firstOrNull ??
        devices.first;

    T? wrap<T>(UpnpService? s, T Function(SoapClient, UpnpService) f) => s == null ? null : f(soap, s);
    final rc = find((t) => upnp(t, 'RenderingControl'));
    final cm = find((t) => upnp(t, 'ConnectionManager'));
    final ext = find((t) => t.startsWith(PlaylistExtension.serviceTypePrefix));
    return MediaRenderer._(
      main,
      devices,
      client,
      transport: wrap(avt, AVTransport.new),
      renderingControl: wrap(rc, RenderingControl.new),
      connectionManager: wrap(cm, ConnectionManager.new),
      ohPlaylist: wrap(playlist, OhPlaylist.new),
      ohTime: wrap(find((t) => oh(t, 'Time')), OhTime.new),
      ohProduct: wrap(find((t) => oh(t, 'Product')), OhProduct.new),
      ohVolume: wrap(find((t) => oh(t, 'Volume')), OhVolume.new),
      playlistExtension: avt == null ? null : wrap(ext, PlaylistExtension.new),
    );
  }

  String get udn => device.udn;
  String get name => device.friendlyName;

  /// UDNs of every device this renderer was assembled from, for matching
  /// SSDP announcements.
  Set<String> get udns => {for (final d in parts) d.udn};

  QueueStrategy get strategy => ohPlaylist != null
      ? QueueStrategy.openHome
      : playlistExtension != null
          ? QueueStrategy.playlistExtension
          : QueueStrategy.avTransport;

  /// Whether playback continues without the phone.
  bool get holdsQueue => strategy != QueueStrategy.avTransport;

  /// Formats the renderer accepts. Cached; an empty list means unknown, in
  /// which case callers should assume common formats.
  Future<List<ProtocolInfo>> sinks() async {
    if (_sinks != null) return _sinks!;
    try {
      _sinks = connectionManager != null
          ? await connectionManager!.sinkProtocols()
          : await ohPlaylist?.protocolInfo() ?? const [];
    } on Object {
      _sinks = const [];
    }
    return _sinks!;
  }

  Future<bool> supportsSetNext() async {
    final t = transport;
    if (t == null) return false;
    return _supportsSetNext ??= await AVTransport.supportsSetNext(t.service, (u) async {
      final r = await _http.get(u).timeout(const Duration(seconds: 5));
      return utf8.decode(r.bodyBytes, allowMalformed: true);
    });
  }

  /// A queue using the best strategy this renderer supports.
  Future<RendererQueue> createQueue({Duration pollInterval = const Duration(seconds: 1)}) async {
    switch (strategy) {
      case QueueStrategy.openHome:
        return RendererHeldQueue(
          OpenHomeBackend(ohPlaylist!, time: ohTime, product: ohProduct),
          pollInterval: pollInterval,
        );
      case QueueStrategy.playlistExtension:
        return RendererHeldQueue(
          PlaylistExtensionBackend(playlistExtension!, transport!),
          pollInterval: pollInterval,
        );
      case QueueStrategy.avTransport:
        return AvTransportQueue(
          transport: transport!,
          renderingControl: renderingControl,
          sinks: await sinks(),
          supportsSetNext: await supportsSetNext(),
          pollInterval: pollInterval,
        );
    }
  }

  Future<int?> volume() async =>
      ohVolume != null ? ohVolume!.volume() : renderingControl?.volume();

  Future<void> setVolume(int v) async =>
      ohVolume != null ? ohVolume!.setVolume(v) : renderingControl?.setVolume(v);
}
