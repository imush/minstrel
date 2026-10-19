import 'didl.dart';
import 'device.dart';
import 'protocol_info.dart';
import 'soap.dart';
import 'upnp_time.dart';

class BrowseResult {
  final List<DidlObject> objects;
  final int totalMatches;
  final int updateId;

  const BrowseResult(this.objects, this.totalMatches, this.updateId);
}

/// ContentDirectory:1 client.
class ContentDirectory {
  final SoapClient _soap;
  final UpnpService service;

  ContentDirectory(this._soap, this.service);

  Future<BrowseResult> browse(
    String objectId, {
    int start = 0,
    int count = 200,
    String filter = '*',
    String sort = '',
  }) =>
      _query('Browse', {
        'ObjectID': objectId,
        'BrowseFlag': 'BrowseDirectChildren',
        'Filter': filter,
        'StartingIndex': start,
        'RequestedCount': count,
        'SortCriteria': sort,
      });

  Future<DidlObject?> metadata(String objectId) async {
    final r = await _query('Browse', {
      'ObjectID': objectId,
      'BrowseFlag': 'BrowseMetadata',
      'Filter': '*',
      'StartingIndex': 0,
      'RequestedCount': 0,
      'SortCriteria': '',
    });
    return r.objects.firstOrNull;
  }

  Future<BrowseResult> search(
    String containerId,
    String criteria, {
    int start = 0,
    int count = 200,
  }) =>
      _query('Search', {
        'ContainerID': containerId,
        'SearchCriteria': criteria,
        'Filter': '*',
        'StartingIndex': start,
        'RequestedCount': count,
        'SortCriteria': '',
      });

  /// All children of [objectId], fetched page by page. Servers may return
  /// fewer than requested per page, and some report TotalMatches as 0 when
  /// unknown, so paging stops on an empty page.
  Stream<List<DidlObject>> browseAll(String objectId, {int pageSize = 200}) async* {
    var start = 0;
    while (true) {
      final page = await browse(objectId, start: start, count: pageSize);
      if (page.objects.isEmpty) return;
      yield page.objects;
      start += page.objects.length;
      if (page.totalMatches > 0 && start >= page.totalMatches) return;
    }
  }

  /// The audio tracks under [containerId], depth first, for queueing a
  /// whole album, work or composer.
  ///
  /// Libraries often list the same track under several branches (MinimServer
  /// shows a composer's tracks by album, as a flat list and by artist), so
  /// tracks are de-duplicated by URL. [maxTracks] and [maxRequests] bound the
  /// work for very large containers.
  Future<List<DidlItem>> collectTracks(
    String containerId, {
    int maxTracks = 1000,
    int maxRequests = 200,
  }) async {
    final tracks = <DidlItem>[];
    final seen = <String>{};
    var requests = 0;

    Future<void> visit(String id) async {
      final children = <DidlObject>[];
      var start = 0;
      while (requests < maxRequests) {
        requests++;
        final page = await browse(id, start: start);
        children.addAll(page.objects);
        start += page.objects.length;
        if (page.objects.isEmpty || (page.totalMatches > 0 && start >= page.totalMatches)) break;
      }
      for (final c in children) {
        if (tracks.length >= maxTracks) return;
        if (c is DidlItem && c.isAudio) {
          final key = c.resources.firstOrNull?.uri.toString() ?? c.id;
          if (seen.add(key)) tracks.add(c);
        }
      }
      for (final c in children) {
        if (tracks.length >= maxTracks || requests >= maxRequests) return;
        if (c is DidlContainer) await visit(c.id);
      }
    }

    await visit(containerId);
    return tracks;
  }

  Future<String> searchCapabilities() async =>
      (await _soap.invoke(service.controlUrl, service.serviceType,
              'GetSearchCapabilities', const {}))['SearchCaps'] ??
          '';

  Future<BrowseResult> _query(String action, Map<String, Object> args) async {
    final r = await _soap.invoke(
        service.controlUrl, service.serviceType, action, args);
    final xml = r['Result'] ?? '';
    return BrowseResult(
      xml.trim().isEmpty ? const [] : parseDidlLite(xml, base: service.controlUrl),
      int.tryParse(r['TotalMatches'] ?? '') ?? 0,
      int.tryParse(r['UpdateID'] ?? '') ?? 0,
    );
  }
}

enum TransportState {
  stopped,
  playing,
  paused,
  transitioning,
  noMediaPresent,
  unknown;

  static TransportState parse(String? s) => switch (s) {
        'STOPPED' => stopped,
        'PLAYING' => playing,
        'PAUSED_PLAYBACK' => paused,
        'TRANSITIONING' => transitioning,
        'NO_MEDIA_PRESENT' => noMediaPresent,
        _ => unknown,
      };
}

class PositionInfo {
  final int track;
  final Duration? duration;
  final Duration? position;
  final String? trackUri;
  final String? trackMetadata;

  const PositionInfo(
      this.track, this.duration, this.position, this.trackUri, this.trackMetadata);
}

/// AVTransport:1 client, always on instance 0.
class AVTransport {
  final SoapClient _soap;
  final UpnpService service;

  AVTransport(this._soap, this.service);

  Future<Map<String, String>> _call(String action, [Map<String, Object> args = const {}]) =>
      _soap.invoke(service.controlUrl, service.serviceType, action,
          {'InstanceID': 0, ...args});

  Future<void> setUri(Uri uri, String metadata) => _call('SetAVTransportURI',
      {'CurrentURI': uri.toString(), 'CurrentURIMetaData': metadata});

  Future<void> setNextUri(Uri? uri, String metadata) =>
      _call('SetNextAVTransportURI', {
        'NextURI': uri?.toString() ?? '',
        'NextURIMetaData': uri == null ? '' : metadata,
      });

  Future<void> play() => _call('Play', {'Speed': '1'});
  Future<void> pause() => _call('Pause');
  Future<void> stop() => _call('Stop');
  Future<void> next() => _call('Next');
  Future<void> previous() => _call('Previous');

  Future<void> seek(Duration position) =>
      _call('Seek', {'Unit': 'REL_TIME', 'Target': formatUpnpDuration(position)});

  Future<TransportState> transportState() async =>
      TransportState.parse((await _call('GetTransportInfo'))['CurrentTransportState']);

  Future<PositionInfo> positionInfo() async {
    final r = await _call('GetPositionInfo');
    return PositionInfo(
      int.tryParse(r['Track'] ?? '') ?? 0,
      parseUpnpDuration(r['TrackDuration']),
      parseUpnpDuration(r['RelTime']),
      r['TrackURI'],
      r['TrackMetaData'],
    );
  }

  /// Whether the device's action list includes SetNextAVTransportURI.
  /// Without it, gapless handover on the renderer is impossible.
  static Future<bool> supportsSetNext(UpnpService service, Future<String> Function(Uri) fetch) async {
    try {
      return (await fetch(service.scpdUrl)).contains('SetNextAVTransportURI');
    } on Object {
      return false;
    }
  }
}

/// RenderingControl:1 client (master channel volume and mute).
class RenderingControl {
  final SoapClient _soap;
  final UpnpService service;

  RenderingControl(this._soap, this.service);

  Future<Map<String, String>> _call(String action, [Map<String, Object> args = const {}]) =>
      _soap.invoke(service.controlUrl, service.serviceType, action,
          {'InstanceID': 0, 'Channel': 'Master', ...args});

  Future<int?> volume() async => int.tryParse((await _call('GetVolume'))['CurrentVolume'] ?? '');
  Future<void> setVolume(int v) => _call('SetVolume', {'DesiredVolume': v});
  Future<bool> mute() async => (await _call('GetMute'))['CurrentMute'] == '1';
  Future<void> setMute(bool m) => _call('SetMute', {'DesiredMute': m ? '1' : '0'});
}

/// ConnectionManager:1 client; only GetProtocolInfo is needed.
class ConnectionManager {
  final SoapClient _soap;
  final UpnpService service;

  ConnectionManager(this._soap, this.service);

  Future<List<ProtocolInfo>> sinkProtocols() async {
    final r = await _soap.invoke(
        service.controlUrl, service.serviceType, 'GetProtocolInfo', const {});
    return ProtocolInfo.parseList(r['Sink']);
  }
}
