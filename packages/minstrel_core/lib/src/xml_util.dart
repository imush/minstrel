import 'package:xml/xml.dart';

/// Namespace-agnostic helpers. UPnP devices are inconsistent about
/// namespaces and prefixes, so elements are matched by local name only.
extension XmlLocal on XmlElement {
  Iterable<XmlElement> children$(String localName) =>
      childElements.where((e) => e.name.local == localName);

  XmlElement? child(String localName) {
    for (final e in childElements) {
      if (e.name.local == localName) return e;
    }
    return null;
  }

  String? childText(String localName) {
    final text = child(localName)?.innerText.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  Iterable<XmlElement> descendants$(String localName) =>
      descendantElements.where((e) => e.name.local == localName);

  /// Attribute by local name, ignoring any prefix.
  String? attr(String localName) {
    for (final a in attributes) {
      if (a.name.local == localName) return a.value;
    }
    return null;
  }
}

String xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
