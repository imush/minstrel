import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'xml_util.dart';

/// A SOAP fault from a UPnP action, such as 701 (transition not available)
/// or 714 (illegal MIME type).
class UpnpActionException implements Exception {
  final String action;
  final int? code;
  final String? description;
  final int? httpStatus;

  UpnpActionException(this.action,
      {this.code, this.description, this.httpStatus});

  @override
  String toString() =>
      'UpnpActionException($action: ${code ?? 'HTTP $httpStatus'} ${description ?? ''})';
}

class SoapClient {
  final http.Client _http;
  final Duration timeout;

  SoapClient(this._http, {this.timeout = const Duration(seconds: 15)});

  /// Invokes [action] and returns the response arguments by name.
  /// Argument order matters to some devices, so pass an ordered map.
  Future<Map<String, String>> invoke(
    Uri controlUrl,
    String serviceType,
    String action,
    Map<String, Object> args,
  ) async {
    final body = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">')
      ..write('<s:Body><u:$action xmlns:u="$serviceType">');
    args.forEach((k, v) => body.write('<$k>${xmlEscape('$v')}</$k>'));
    body.write('</u:$action></s:Body></s:Envelope>');

    final response = await _http
        .post(
          controlUrl,
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPACTION': '"$serviceType#$action"',
            // Embedded UPnP servers often drop idle keep-alive connections
            // without telling the client; a fresh connection per call is safe.
            'Connection': 'close',
          },
          body: utf8.encode(body.toString()),
        )
        .timeout(timeout);

    // Decode as UTF-8 regardless of headers; many devices omit the charset.
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlException {
      throw UpnpActionException(action,
          httpStatus: response.statusCode, description: 'malformed response');
    }

    final fault = doc.rootElement.descendants$('UPnPError').firstOrNull;
    if (fault != null || response.statusCode != 200) {
      throw UpnpActionException(
        action,
        code: int.tryParse(fault?.childText('errorCode') ?? ''),
        description: fault?.childText('errorDescription'),
        httpStatus: response.statusCode,
      );
    }

    final resp = doc.rootElement.descendants$('${action}Response').firstOrNull;
    if (resp == null) {
      throw UpnpActionException(action,
          httpStatus: response.statusCode, description: 'no response element');
    }
    return {for (final e in resp.childElements) e.name.local: e.innerText};
  }
}
