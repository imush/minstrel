import 'dart:convert';

import 'package:xml/xml.dart';

import 'didl.dart';
import 'protocol_info.dart';
import 'renderer_held_queue.dart' show normaliseUri;
import 'renderer_queue.dart';
import 'upnp_time.dart';
import 'xml_util.dart';

/// The queue as saved between app runs: the tracks with their full server
/// metadata, where playback was, and on which output.
class QueueSnapshot {
  static const _version = 1;

  final String outputId;
  final List<QueueEntry> entries;
  final int index;
  final Duration position;

  const QueueSnapshot({
    required this.outputId,
    required this.entries,
    required this.index,
    required this.position,
  });

  String encode() => jsonEncode({
        'v': _version,
        'output': outputId,
        'index': index,
        'positionMs': position.inMilliseconds,
        'entries': [
          for (final e in entries) {'didl': e.item.rawXml, 'res': e.resource.uri.toString()},
        ],
      });

  /// Returns null for anything unreadable, including other versions; a lost
  /// queue is better than a crash at startup.
  static QueueSnapshot? decode(String json) {
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      if (m['v'] != _version) return null;
      final entries = <QueueEntry>[];
      for (final e in (m['entries'] as List).cast<Map<String, dynamic>>()) {
        final entry = queueEntryFromMetadata(
            Uri.parse(e['res'] as String), wrapDidlLite(e['didl'] as String));
        entries.add(entry);
      }
      return QueueSnapshot(
        outputId: m['output'] as String,
        entries: entries,
        index: (m['index'] as int).clamp(-1, entries.length - 1),
        position: Duration(milliseconds: m['positionMs'] as int),
      );
    } on Object {
      return null;
    }
  }
}

/// Builds a queue entry for the track at [uri] from DIDL-Lite [metadata],
/// as saved by the app or as stored by a renderer. Renderers often keep a
/// trimmed copy: no item id, and a `<res>` with attributes but no URL. The
/// resource is matched by URL when present, otherwise taken from the first
/// `<res>`'s attributes.
///
/// Such a trimmed copy can't be sent back as is: the CXNv2 doesn't
/// recognise metadata whose `<res>` lacks a URL or protocolInfo, and stores
/// the whole document as the title, with no duration; it then also ignores
/// Pause. So the entry gets a complete `<res>`, with the format guessed from
/// the file name when the renderer dropped it. Metadata it already mangled
/// is recovered from the title.
QueueEntry queueEntryFromMetadata(Uri uri, String metadata) {
  DidlItem? item;
  XmlElement? res;
  try {
    item = parseDidlLite(metadata).whereType<DidlItem>().firstOrNull;
    final itemXml = XmlDocument.parse(metadata).rootElement.child('item');
    final target = normaliseUri(uri.toString());
    final all = itemXml?.children$('res').toList() ?? const [];
    res = all.where((r) => normaliseUri(r.innerText) == target).firstOrNull ?? all.firstOrNull;
  } on Object {
    // Unparseable metadata: fall back to the URL alone.
  }

  // Metadata the CXNv2 already mangled: the original is in the title.
  final title = item?.title.trim() ?? '';
  if (title.startsWith('<DIDL-Lite') && title != metadata.trim()) {
    return queueEntryFromMetadata(uri, title);
  }

  final protocolInfo = ProtocolInfo.parse(res?.attr('protocolInfo'));
  final resource = DidlResource(
    uri: uri,
    protocolInfo: protocolInfo ?? _guessProtocolInfo(uri),
    duration: parseUpnpDuration(res?.attr('duration')),
    size: int.tryParse(res?.attr('size') ?? ''),
    bitrate: int.tryParse(res?.attr('bitrate') ?? ''),
    sampleFrequency: int.tryParse(res?.attr('sampleFrequency') ?? ''),
    bitsPerSample: int.tryParse(res?.attr('bitsPerSample') ?? ''),
    channels: int.tryParse(res?.attr('nrAudioChannels') ?? ''),
  );

  final i = item;
  final complete = protocolInfo != null && res != null && res.innerText.trim().isNotEmpty;
  return QueueEntry(
    DidlItem(
      id: i?.id ?? '',
      parentId: i?.parentId ?? '',
      title: (i?.title.isNotEmpty ?? false) ? i!.title : _titleFromUri(uri),
      upnpClass: i?.upnpClass ?? 'object.item.audioItem.musicTrack',
      artists: i?.artists ?? const [],
      creators: i?.creators ?? const [],
      album: i?.album,
      genre: i?.genre,
      date: i?.date,
      albumArt: i?.albumArt,
      rawXml: (() {
        final xml = i?.rawXml ??
            '<item id="" parentID=""><dc:title>${xmlEscape(_titleFromUri(uri))}</dc:title></item>';
        return complete ? xml : itemXmlWithResource(xml, resource);
      })(),
      resources: (i?.resources.isNotEmpty ?? false) ? i!.resources : [resource],
      trackNumber: i?.trackNumber,
    ),
    resource,
  );
}

const _mimeByExtension = {
  'flac': 'audio/flac',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/wav',
  'aif': 'audio/aiff',
  'aiff': 'audio/aiff',
  'ogg': 'audio/ogg',
  'dsf': 'audio/dsf',
  'dff': 'audio/dff',
  'wma': 'audio/wma',
};

ProtocolInfo _guessProtocolInfo(Uri uri) {
  final name = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
  final dot = name.lastIndexOf('.');
  final mime = dot < 0 ? null : _mimeByExtension[name.substring(dot + 1).toLowerCase()];
  return ProtocolInfo.parse('http-get:*:${mime ?? '*'}:*')!;
}

String _titleFromUri(Uri uri) {
  final last = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? uri.toString();
  final dot = last.lastIndexOf('.');
  return dot > 0 ? last.substring(0, dot) : last;
}
