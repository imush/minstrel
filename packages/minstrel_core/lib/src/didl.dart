import 'package:xml/xml.dart';

import 'protocol_info.dart';
import 'upnp_time.dart';
import 'xml_util.dart';

/// A person credited on an object, with the DIDL role attribute when present
/// (Composer, Conductor, Performer, AlbumArtist, ...).
class Contributor {
  final String name;
  final String? role;

  const Contributor(this.name, [this.role]);

  @override
  String toString() => role == null ? name : '$name ($role)';
}

/// One `<res>` element: a URL at which the object can be fetched, in one
/// particular format. Servers that transcode list several of these.
class DidlResource {
  final Uri uri;
  final ProtocolInfo? protocolInfo;
  final Duration? duration;
  final int? size;
  final int? bitrate; // bytes per second, per the UPnP spec
  final int? sampleFrequency;
  final int? bitsPerSample;
  final int? channels;

  const DidlResource({
    required this.uri,
    this.protocolInfo,
    this.duration,
    this.size,
    this.bitrate,
    this.sampleFrequency,
    this.bitsPerSample,
    this.channels,
  });

  String? get mimeType => protocolInfo?.mimeType;

  DidlResource withUri(Uri uri) => DidlResource(
        uri: uri,
        protocolInfo: protocolInfo,
        duration: duration,
        size: size,
        bitrate: bitrate,
        sampleFrequency: sampleFrequency,
        bitsPerSample: bitsPerSample,
        channels: channels,
      );

  bool get isLossless => const {
        'audio/flac',
        'audio/wav',
        'audio/aiff',
        'audio/l16',
        'audio/dsf',
        'audio/dff',
      }.contains(mimeType);

  /// Short human-readable format, such as `FLAC 24/96`.
  String get formatLabel {
    final mime = mimeType ?? '';
    final name = switch (mime) {
      'audio/flac' => 'FLAC',
      'audio/mpeg' => 'MP3',
      'audio/mp4' => 'AAC',
      'audio/aac' => 'AAC',
      'audio/wav' => 'WAV',
      'audio/aiff' => 'AIFF',
      'audio/l16' => 'PCM',
      'audio/ogg' => 'Ogg',
      'audio/dsf' || 'audio/dff' => 'DSD',
      'audio/wma' => 'WMA',
      _ => mime.contains('/') ? mime.split('/').last.toUpperCase() : '?',
    };
    if (isLossless && sampleFrequency != null) {
      final khz = sampleFrequency! / 1000;
      final rate = khz == khz.roundToDouble()
          ? khz.toStringAsFixed(0)
          : khz.toStringAsFixed(1);
      return bitsPerSample != null ? '$name $bitsPerSample/$rate' : '$name $rate kHz';
    }
    if (!isLossless && bitrate != null) {
      return '$name ${(bitrate! * 8 / 1000).round()}k';
    }
    return name;
  }

  static DidlResource? fromXml(XmlElement e, {Uri? base}) {
    final text = e.innerText.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    return DidlResource(
      uri: base != null ? base.resolveUri(uri) : uri,
      protocolInfo: ProtocolInfo.parse(e.attr('protocolInfo')),
      duration: parseUpnpDuration(e.attr('duration')),
      size: int.tryParse(e.attr('size') ?? ''),
      bitrate: int.tryParse(e.attr('bitrate') ?? ''),
      sampleFrequency: int.tryParse(e.attr('sampleFrequency') ?? ''),
      bitsPerSample: int.tryParse(e.attr('bitsPerSample') ?? ''),
      channels: int.tryParse(e.attr('nrAudioChannels') ?? ''),
    );
  }
}

/// A container or item from a ContentDirectory Browse or Search result.
sealed class DidlObject {
  final String id;
  final String parentId;
  final String title;
  final String upnpClass;
  final List<Contributor> artists;
  final List<Contributor> creators;
  final String? album;
  final String? genre;
  final String? date;
  final Uri? albumArt;

  /// The original `<item>` or `<container>` XML, kept so it can be handed to
  /// a renderer as metadata unchanged (renderers display what servers send).
  final String rawXml;

  const DidlObject({
    required this.id,
    required this.parentId,
    required this.title,
    required this.upnpClass,
    required this.artists,
    required this.creators,
    required this.album,
    required this.genre,
    required this.date,
    required this.albumArt,
    required this.rawXml,
  });

  /// Contributors with the given role, case-insensitive.
  Iterable<String> withRole(String role) => artists
      .where((a) => a.role?.toLowerCase() == role.toLowerCase())
      .map((a) => a.name);

  /// The main performer line: artists without a role, falling back to
  /// dc:creator. Composers and album artists are reported separately.
  String? get performer {
    final plain = artists.where((a) => a.role == null).map((a) => a.name);
    if (plain.isNotEmpty) return plain.toSet().join(', ');
    final creator = creators.map((c) => c.name);
    return creator.isEmpty ? null : creator.toSet().join(', ');
  }

  String? get composer {
    final c = withRole('Composer').toSet();
    return c.isEmpty ? null : c.join(', ');
  }

  String? get conductor {
    final c = withRole('Conductor').toSet();
    return c.isEmpty ? null : c.join(', ');
  }
}

class DidlContainer extends DidlObject {
  final int? childCount;
  final bool searchable;

  const DidlContainer({
    required super.id,
    required super.parentId,
    required super.title,
    required super.upnpClass,
    required super.artists,
    required super.creators,
    required super.album,
    required super.genre,
    required super.date,
    required super.albumArt,
    required super.rawXml,
    required this.childCount,
    required this.searchable,
  });
}

class DidlItem extends DidlObject {
  final List<DidlResource> resources;
  final int? trackNumber;

  const DidlItem({
    required super.id,
    required super.parentId,
    required super.title,
    required super.upnpClass,
    required super.artists,
    required super.creators,
    required super.album,
    required super.genre,
    required super.date,
    required super.albumArt,
    required super.rawXml,
    required this.resources,
    required this.trackNumber,
  });

  bool get isAudio => upnpClass.startsWith('object.item.audioItem');

  Duration? get duration {
    for (final r in resources) {
      if (r.duration != null) return r.duration;
    }
    return null;
  }

  /// DIDL-Lite document describing just this item, for
  /// SetAVTransportURI / SetNextAVTransportURI metadata.
  String toDidlLite() => wrapDidlLite(rawXml);
}

const _didlOpen =
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
    'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">';

String wrapDidlLite(String inner) => '$_didlOpen$inner</DIDL-Lite>';

/// Parses a DIDL-Lite document. Relative URLs are resolved against [base].
/// Malformed objects are skipped rather than failing the whole page.
List<DidlObject> parseDidlLite(String xml, {Uri? base}) {
  final doc = XmlDocument.parse(xml);
  final root = doc.rootElement;
  final result = <DidlObject>[];
  for (final e in root.childElements) {
    final kind = e.name.local;
    if (kind != 'item' && kind != 'container') continue;
    // Renderers that store metadata often strip the id from items.
    final id = e.attr('id') ?? (kind == 'item' ? '' : null);
    if (id == null) continue;

    final artists = e
        .children$('artist')
        .map((a) => Contributor(a.innerText.trim(), _role(a)))
        .where((a) => a.name.isNotEmpty)
        .toList();
    final creators = e
        .children$('creator')
        .map((a) => Contributor(a.innerText.trim(), _role(a)))
        .where((a) => a.name.isNotEmpty)
        .toList();
    final artText = e.childText('albumArtURI');
    final art = artText == null ? null : Uri.tryParse(artText);

    final raw = _serialiseDetached(e, root);

    final common = (
      id: id,
      parentId: e.attr('parentID') ?? '',
      title: e.childText('title') ?? '',
      upnpClass: e.childText('class') ?? '',
      album: e.childText('album'),
      genre: e.childText('genre'),
      date: e.childText('date'),
      albumArt: art == null ? null : (base?.resolveUri(art) ?? art),
    );

    if (kind == 'container') {
      result.add(DidlContainer(
        id: common.id,
        parentId: common.parentId,
        title: common.title,
        upnpClass: common.upnpClass,
        artists: artists,
        creators: creators,
        album: common.album,
        genre: common.genre,
        date: common.date,
        albumArt: common.albumArt,
        rawXml: raw,
        childCount: int.tryParse(e.attr('childCount') ?? ''),
        searchable: e.attr('searchable') == '1' || e.attr('searchable') == 'true',
      ));
    } else {
      result.add(DidlItem(
        id: common.id,
        parentId: common.parentId,
        title: common.title,
        upnpClass: common.upnpClass,
        artists: artists,
        creators: creators,
        album: common.album,
        genre: common.genre,
        date: common.date,
        albumArt: common.albumArt,
        rawXml: raw,
        resources: e
            .children$('res')
            .map((r) => DidlResource.fromXml(r, base: base))
            .whereType<DidlResource>()
            .toList(),
        trackNumber: int.tryParse(e.childText('originalTrackNumber') ?? ''),
      ));
    }
  }
  return result;
}

String? _role(XmlElement e) {
  final r = e.attr('role')?.trim();
  return (r == null || r.isEmpty) ? null : r;
}

/// Serialises [e] so it stands alone: namespace declarations it inherited
/// from the DIDL-Lite root (including vendor ones) are copied onto it.
String _serialiseDetached(XmlElement e, XmlElement root) {
  final copy = e.copy();
  final declared = copy.attributes.map((a) => a.name.qualified).toSet();
  for (final a in root.attributes) {
    final isNs = a.name.prefix == 'xmlns' || a.name.qualified == 'xmlns';
    if (isNs && !declared.contains(a.name.qualified)) {
      copy.attributes.add(a.copy());
    }
  }
  return copy.toXmlString();
}
