import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'device.dart';
import 'protocol_info.dart';
import 'soap.dart';
import 'xml_util.dart';

/// Decodes an OpenHome IdArray: base64 of big-endian 32-bit track ids.
/// The Cambridge PlaylistExtension service uses the same encoding.
List<int> decodeIdArray(String base64Ids) {
  final s = base64Ids.trim();
  if (s.isEmpty) return const [];
  final bytes = base64.decode(s);
  final data = ByteData.sublistView(bytes);
  return [for (var i = 0; i + 4 <= bytes.length; i += 4) data.getUint32(i)];
}

/// One track of a renderer-side playlist as the renderer reports it.
class PlaylistEntry {
  final int id;
  final Uri uri;

  /// DIDL-Lite as stored by the renderer; often trimmed compared with what
  /// the server sent.
  final String metadata;

  const PlaylistEntry(this.id, this.uri, this.metadata);
}

/// Parses ReadList results: OpenHome's `<TrackList>` and Cambridge's
/// `<MetaDataList>` share the Entry/Id/Uri/Metadata shape (Cambridge
/// spells it MetaData and suffixes ids with `l`).
List<PlaylistEntry> parsePlaylistEntries(String xml) {
  if (xml.trim().isEmpty) return const [];
  final result = <PlaylistEntry>[];
  for (final e in XmlDocument.parse(xml).rootElement.children$('Entry')) {
    final id = int.tryParse((e.childText('Id') ?? '').replaceAll(RegExp(r'[^0-9]'), ''));
    final uri = Uri.tryParse(e.childText('Uri') ?? '');
    if (id == null || uri == null) continue;
    result.add(PlaylistEntry(id, uri, e.childText('Metadata') ?? e.childText('MetaData') ?? ''));
  }
  return result;
}

/// Reads [ids] in batches; renderers limit how many one call may return.
Future<List<PlaylistEntry>> _readInBatches(
    List<int> ids, Future<List<PlaylistEntry>> Function(List<int>) read) async {
  final result = <PlaylistEntry>[];
  for (var i = 0; i < ids.length; i += 50) {
    result.addAll(await read(ids.sublist(i, (i + 50).clamp(0, ids.length))));
  }
  return result;
}

abstract class _ServiceClient {
  final SoapClient soap;
  final UpnpService service;

  _ServiceClient(this.soap, this.service);

  Future<Map<String, String>> call(String action, [Map<String, Object> args = const {}]) =>
      soap.invoke(service.controlUrl, service.serviceType, action, args);
}

/// OpenHome Playlist:1. The renderer holds the queue and plays through it
/// by itself.
class OhPlaylist extends _ServiceClient {
  OhPlaylist(super.soap, super.service);

  Future<void> play() => call('Play');
  Future<void> pause() => call('Pause');
  Future<void> stop() => call('Stop');
  Future<void> next() => call('Next');
  Future<void> previous() => call('Previous');
  Future<void> seekId(int id) => call('SeekId', {'Value': id});
  Future<void> seekSecondAbsolute(int s) => call('SeekSecondAbsolute', {'Value': s});
  Future<void> deleteAll() => call('DeleteAll');
  Future<void> deleteId(int id) => call('DeleteId', {'Value': id});

  Future<int> insert(int afterId, Uri uri, String metadata) async => int.parse(
      (await call('Insert', {'AfterId': afterId, 'Uri': uri.toString(), 'Metadata': metadata}))[
          'NewId']!);

  /// `Playing`, `Paused`, `Stopped` or `Buffering`.
  Future<String> transportState() async => (await call('TransportState'))['Value'] ?? '';

  /// Id of the current track, 0 when there is none.
  Future<int> id() async => int.tryParse((await call('Id'))['Value'] ?? '') ?? 0;

  Future<List<int>> idArray() async => decodeIdArray((await call('IdArray'))['Array'] ?? '');

  /// The renderer's playlist, in order. OpenHome separates ids with spaces.
  Future<List<PlaylistEntry>> readAll() async => _readInBatches(
      await idArray(),
      (ids) async =>
          parsePlaylistEntries((await call('ReadList', {'IdList': ids.join(' ')}))['TrackList'] ?? ''));

  Future<List<ProtocolInfo>> protocolInfo() async =>
      ProtocolInfo.parseList((await call('ProtocolInfo'))['Value']);
}

/// OpenHome Time:1: position within the current track.
class OhTime extends _ServiceClient {
  OhTime(super.soap, super.service);

  Future<({Duration duration, Duration position})> time() async {
    final r = await call('Time');
    return (
      duration: Duration(seconds: int.tryParse(r['Duration'] ?? '') ?? 0),
      position: Duration(seconds: int.tryParse(r['Seconds'] ?? '') ?? 0),
    );
  }
}

/// OpenHome Product:1, used to switch the device to its Playlist source
/// (it may be on radio, an input, AirPlay, ...).
class OhProduct extends _ServiceClient {
  OhProduct(super.soap, super.service);

  Future<void> selectPlaylistSource() async {
    final xml = (await call('SourceXml'))['Value'] ?? '';
    if (xml.isEmpty) return;
    final sources = XmlDocument.parse(xml).rootElement.children$('Source').toList();
    final index = sources.indexWhere((s) => s.childText('Type') == 'Playlist');
    if (index < 0) return;
    final current = int.tryParse((await call('SourceIndex'))['Value'] ?? '');
    if (current != index) await call('SetSourceIndex', {'Value': index});
  }
}

/// OpenHome Volume:1.
class OhVolume extends _ServiceClient {
  OhVolume(super.soap, super.service);

  Future<int?> volume() async => int.tryParse((await call('Volume'))['Value'] ?? '');
  Future<void> setVolume(int v) => call('SetVolume', {'Value': v});
}

/// Cambridge Audio StreamMagic `PlaylistExtension:1`: a renderer-side list
/// that AVTransport plays through. Same id model as OpenHome Playlist, but
/// transport control goes through AVTransport.
class PlaylistExtension extends _ServiceClient {
  PlaylistExtension(super.soap, super.service);

  static const serviceTypePrefix = 'urn:UuVol-com:service:PlaylistExtension:';

  Future<void> deleteAll() => call('DeleteAll');
  Future<void> delete(int id) => call('Delete', {'aId': id});

  Future<int> insert(int afterId, Uri uri, String metadata) async => int.parse(
      (await call('Insert', {'aAfterId': afterId, 'aUri': uri.toString(), 'aMetaData': metadata}))[
          'aNewId']!);

  Future<List<int>> idArray() async => decodeIdArray((await call('IdArray'))['aIdArray'] ?? '');

  /// The renderer's playlist, in order. Ids must be comma-separated: with
  /// spaces the CXNv2 returns only the first entry.
  Future<List<PlaylistEntry>> readAll() async => _readInBatches(
      await idArray(),
      (ids) async => parsePlaylistEntries(
          (await call('ReadList', {'aIdList': ids.join(',')}))['aMetaDataList'] ?? ''));
}
