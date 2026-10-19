import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'xml_util.dart';

class UpnpService {
  final String serviceType;
  final String serviceId;
  final Uri controlUrl;
  final Uri eventSubUrl;
  final Uri scpdUrl;

  const UpnpService({
    required this.serviceType,
    required this.serviceId,
    required this.controlUrl,
    required this.eventSubUrl,
    required this.scpdUrl,
  });

  /// `urn:schemas-upnp-org:service:AVTransport:1` -> `AVTransport`.
  String get shortType {
    final parts = serviceType.split(':');
    return parts.length >= 2 ? parts[parts.length - 2] : serviceType;
  }
}

class DeviceIcon {
  final Uri url;
  final String? mimeType;
  final int? width;

  const DeviceIcon(this.url, this.mimeType, this.width);
}

/// A UPnP device parsed from its description document. Embedded devices
/// are flattened by [UpnpDevice.parseAll], since media servers and renderers
/// are sometimes nested inside a root device.
class UpnpDevice {
  final String udn;
  final String deviceType;
  final String friendlyName;
  final String? manufacturer;
  final String? modelName;
  final Uri location;
  final List<UpnpService> services;
  final List<DeviceIcon> icons;

  const UpnpDevice({
    required this.udn,
    required this.deviceType,
    required this.friendlyName,
    required this.manufacturer,
    required this.modelName,
    required this.location,
    required this.services,
    required this.icons,
  });

  bool get isMediaServer => deviceType.contains(':device:MediaServer:');
  bool get isMediaRenderer => deviceType.contains(':device:MediaRenderer:');

  UpnpService? service(String shortType) {
    for (final s in services) {
      if (s.shortType == shortType) return s;
    }
    return null;
  }

  /// The largest icon, preferring PNG.
  DeviceIcon? get bestIcon {
    if (icons.isEmpty) return null;
    final sorted = [...icons]..sort((a, b) {
        final byPng = (b.mimeType == 'image/png' ? 1 : 0) -
            (a.mimeType == 'image/png' ? 1 : 0);
        return byPng != 0 ? byPng : (b.width ?? 0) - (a.width ?? 0);
      });
    return sorted.first;
  }

  static Future<List<UpnpDevice>> fetch(http.Client client, Uri location,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final r = await client.get(location).timeout(timeout);
    if (r.statusCode != 200) {
      throw http.ClientException(
          'Device description returned ${r.statusCode}', location);
    }
    return parseAll(utf8.decode(r.bodyBytes, allowMalformed: true), location);
  }

  static List<UpnpDevice> parseAll(String xml, Uri location) {
    final root = XmlDocument.parse(xml).rootElement;
    final urlBase = root.childText('URLBase');
    final base = urlBase != null ? Uri.parse(urlBase) : location;
    final result = <UpnpDevice>[];
    void visit(XmlElement d) {
      final udn = d.childText('UDN');
      final type = d.childText('deviceType');
      if (udn != null && type != null) {
        result.add(_parseOne(d, udn, type, base, location));
      }
      for (final child in d.child('deviceList')?.children$('device') ?? const <XmlElement>[]) {
        visit(child);
      }
    }

    final device = root.child('device');
    if (device != null) visit(device);
    return result;
  }

  static UpnpDevice _parseOne(
      XmlElement d, String udn, String type, Uri base, Uri location) {
    Uri resolve(String? s) => base.resolve(s ?? '');
    final services = <UpnpService>[];
    for (final s in d.child('serviceList')?.children$('service') ?? const <XmlElement>[]) {
      final st = s.childText('serviceType');
      if (st == null) continue;
      services.add(UpnpService(
        serviceType: st,
        serviceId: s.childText('serviceId') ?? '',
        controlUrl: resolve(s.childText('controlURL')),
        eventSubUrl: resolve(s.childText('eventSubURL')),
        scpdUrl: resolve(s.childText('SCPDURL')),
      ));
    }
    final icons = <DeviceIcon>[];
    for (final i in d.child('iconList')?.children$('icon') ?? const <XmlElement>[]) {
      final url = i.childText('url');
      if (url == null) continue;
      icons.add(DeviceIcon(resolve(url), i.childText('mimetype'),
          int.tryParse(i.childText('width') ?? '')));
    }
    return UpnpDevice(
      udn: udn,
      deviceType: type,
      friendlyName: d.childText('friendlyName') ?? udn,
      manufacturer: d.childText('manufacturer'),
      modelName: d.childText('modelName'),
      location: location,
      services: services,
      icons: icons,
    );
  }
}
