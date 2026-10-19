import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// What a minstrel-launchpad's pairing QR code carries:
/// `minstrel://pair?v=1&n=<name>&fp=<key hash>&c=<code>&a=<host:port>...&r=<host:port>...`,
/// where `r` are addresses through a satellite.
class PairingInvitation {
  final String name;
  final String fingerprint;
  final String code;
  final List<String> addresses;
  final List<String> relays;

  const PairingInvitation({
    required this.name,
    required this.fingerprint,
    required this.code,
    required this.addresses,
    this.relays = const [],
  });

  /// Parses a pairing link, or returns null if [text] isn't one.
  static PairingInvitation? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'minstrel' || uri.host != 'pair') return null;
    final q = uri.queryParametersAll;
    String? one(String k) => q[k]?.firstOrNull?.trim();
    final fp = one('fp'), code = one('c');
    List<String> all(String k) => [...?q[k]].map((a) => a.trim()).where((a) => a.isNotEmpty).toList();
    final addresses = all('a'), relays = all('r');
    if (one('v') != '1' || fp == null || fp.isEmpty || code == null || code.isEmpty ||
        addresses.isEmpty && relays.isEmpty) {
      return null;
    }
    return PairingInvitation(
      name: one('n')?.isNotEmpty == true ? one('n')! : 'Home',
      fingerprint: fp,
      code: code,
      addresses: addresses,
      relays: relays,
    );
  }
}

/// A paired launchpad: everything needed to reach a home's music.
class Home {
  final String name;
  final String fingerprint;
  final String token;
  final List<String> addresses;

  /// Addresses through a satellite: tried only when the direct ones don't
  /// answer, since relayed traffic costs the satellite's owner.
  final List<String> relays;
  final String deviceId;

  /// Named on this device; the launchpad's own name no longer replaces it.
  final bool renamed;

  const Home({
    required this.name,
    required this.fingerprint,
    required this.token,
    required this.addresses,
    required this.deviceId,
    this.relays = const [],
    this.renamed = false,
  });

  Home copyWith({String? name, List<String>? addresses, List<String>? relays, bool? renamed}) => Home(
        name: name ?? this.name,
        fingerprint: fingerprint,
        token: token,
        addresses: addresses ?? this.addresses,
        relays: relays ?? this.relays,
        deviceId: deviceId,
        renamed: renamed ?? this.renamed,
      );

  Home withAddresses(List<String> addresses) => copyWith(addresses: addresses);

  /// Stable and URL-safe: the launchpad's key identifies it.
  String get id => fingerprint.substring(0, fingerprint.length.clamp(0, 12));

  Map<String, Object> toJson() => {
    'name': name,
    'fingerprint': fingerprint,
    'token': token,
    'addresses': addresses,
    if (relays.isNotEmpty) 'relays': relays,
    'deviceId': deviceId,
    if (renamed) 'renamed': true,
  };

  static Home fromJson(Map<String, dynamic> j) => Home(
    name: j['name'] as String,
    fingerprint: j['fingerprint'] as String,
    token: j['token'] as String,
    addresses: (j['addresses'] as List).cast<String>(),
    relays: [...?(j['relays'] as List?)?.cast<String>()],
    deviceId: j['deviceId'] as String? ?? '',
    renamed: j['renamed'] as bool? ?? false,
  );
}

enum LaunchpadProblem {
  unreachable('Can\'t reach home. It may be offline, or this network blocks the connection.'),
  wrongCertificate('Something answered at home\'s address, but it isn\'t this launchpad.'),
  notPaired('This device is no longer paired with home. Pair it again.'),
  badCode('The pairing code is wrong, used or expired. Create a new invitation on the launchpad.'),
  blocked('Home is refusing connections after too many failed attempts. Try again in 15 minutes.'),
  serverUnreachable('Home is reachable, but the media server isn\'t responding.'),
  unknownServer('Home doesn\'t know this media server any more.');

  final String message;
  const LaunchpadProblem(this.message);
}

class LaunchpadException implements Exception {
  final LaunchpadProblem problem;
  final Object? cause;

  /// What happened at each address tried, as `address — outcome` lines.
  final List<String> tried;

  const LaunchpadException(this.problem, [this.cause, this.tried = const []]);

  @override
  String toString() => [problem.message, ...tried].join('\n');
}

/// A short account of why a connection attempt failed, for [LaunchpadException.tried].
String describeFailure(Object e, {bool mismatched = false}) => switch (e) {
  _ when mismatched => 'answered with a different certificate',
  TimeoutException() => 'no answer',
  HandshakeException() || TlsException() => 'secure connection failed',
  SocketException(:final osError, :final message) =>
    (osError?.message.isNotEmpty ?? false) ? osError!.message : message,
  HttpException(:final message) => message,
  _ => '$e',
};

/// A media server behind a launchpad, as listed by `/api/info`.
class RemoteServerInfo {
  final String udn;
  final String name;
  final Uri description;
  final Uri? icon;

  const RemoteServerInfo(this.udn, this.name, this.description, this.icon);
}

class LaunchpadInfo {
  final String name;
  final String version;
  final List<RemoteServerInfo> servers;

  /// Where the launchpad can be reached now, outside addresses first; empty
  /// from launchpads too old to say.
  final List<String> addresses;

  /// Addresses through a satellite; null from launchpads too old to say.
  final List<String>? relays;

  /// Compression profiles the launchpad offers (see [HomeProxy.compression]);
  /// empty without ffmpeg there.
  final List<String> transcode;

  const LaunchpadInfo(this.name, this.version, this.servers,
      [this.addresses = const [], this.relays, this.transcode = const []]);

  static LaunchpadInfo fromJson(Map<String, dynamic> j) => LaunchpadInfo(
    j['name'] as String? ?? '',
    j['version'] as String? ?? '',
    [
      for (final s in (j['servers'] as List? ?? const []).cast<Map<String, dynamic>>())
        RemoteServerInfo(
          s['udn'] as String,
          s['name'] as String,
          Uri.parse(s['description'] as String),
          (s['icon'] as String?)?.isNotEmpty == true ? Uri.parse(s['icon'] as String) : null,
        ),
    ],
    [...?(j['addresses'] as List?)?.cast<String>()],
    (j['relays'] as List?)?.cast<String>().toList(),
    [...?(j['transcode'] as List?)?.cast<String>()],
  );
}

/// SHA-256 of a certificate's SubjectPublicKeyInfo, base64url without
/// padding: the launchpad's identity, as shown in its pairing code.
String spkiFingerprint(Uint8List certDer) {
  final digest = sha256.convert(subjectPublicKeyInfo(certDer));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// Extracts the DER SubjectPublicKeyInfo from a DER X.509 certificate.
Uint8List subjectPublicKeyInfo(Uint8List der) {
  ({int tag, int start, int end}) tlv(int off) {
    final tag = der[off];
    var i = off + 1;
    var len = der[i++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | der[i++];
      }
    }
    if (i + len > der.length) throw const FormatException('truncated certificate');
    return (tag: tag, start: i, end: i + len);
  }

  final cert = tlv(0);
  final tbs = tlv(cert.start);
  var off = tbs.start;
  if (tlv(off).tag == 0xA0) off = tlv(off).end; // explicit version
  // serialNumber, signature, issuer, validity, subject
  for (var k = 0; k < 5; k++) {
    off = tlv(off).end;
  }
  return Uint8List.sublistView(der, off, tlv(off).end);
}

/// An HTTPS client that trusts exactly one key, and no certificate
/// authorities: a CA-signed certificate for the same name is refused too.
/// [onMismatch] is called when a different key is presented.
HttpClient pinnedHttpClient(String fingerprint, {void Function()? onMismatch}) {
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 30)
    ..autoUncompress = false
    ..findProxy = (_) => 'DIRECT';
  client.badCertificateCallback = (cert, host, port) {
    final ok = spkiFingerprint(cert.der) == fingerprint;
    if (!ok) onMismatch?.call();
    return ok;
  };
  return client;
}

bool isConnectionError(Object e) =>
    e is SocketException || e is TlsException || e is HttpException || e is TimeoutException;

/// Finds an address that answers as the launchpad: concurrently, first wins
/// (at home that's normally the LAN address). Without a [token] any pinned
/// answer counts; with one it must be accepted.
///
/// [relays], addresses through a satellite, give the direct ones a head
/// start of [relayDelay], or less if those all fail sooner: the satellite is
/// for when home can't be reached directly.
Future<String> findLaunchpad(
  HttpClient client,
  List<String> direct, {
  List<String> relays = const [],
  Duration relayDelay = const Duration(milliseconds: 1500),
  String? token,
  bool Function()? mismatched,
}) async {
  final addresses = [...direct, ...relays];
  if (addresses.isEmpty) throw const LaunchpadException(LaunchpadProblem.unreachable);
  final directDone = Completer<void>();
  var directPending = direct.length;
  if (directPending == 0) directDone.complete();
  final done = Completer<String>();
  final outcomes = List<String?>.filled(addresses.length, null);
  var pending = addresses.length;
  LaunchpadException? worst;
  void failed(int i, LaunchpadException e, String outcome) {
    outcomes[i] = i < direct.length ? outcome : '$outcome (satellite)';
    if (i < direct.length && --directPending == 0) directDone.complete();
    // A definite answer from the launchpad outranks "couldn't connect".
    if (worst == null || worst!.problem == LaunchpadProblem.unreachable) worst = e;
    if (--pending == 0 && !done.isCompleted) {
      done.completeError(
        LaunchpadException(worst!.problem, worst!.cause, [
          for (var j = 0; j < addresses.length; j++) '${addresses[j]} — ${outcomes[j]}',
        ]),
      );
    }
  }

  for (var i = 0; i < addresses.length; i++) {
    final addr = addresses[i];
    () async {
      try {
        if (i >= direct.length) {
          await Future.any([directDone.future, Future<void>.delayed(relayDelay)]);
          if (done.isCompleted) return;
        }
        final rq = await client.getUrl(Uri.parse('https://$addr/api/info'));
        if (token != null) rq.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        final resp = await rq.close().timeout(const Duration(seconds: 10));
        await resp.drain<void>();
        final ok = token == null ? resp.statusCode == 404 : resp.statusCode == 200;
        if (ok) {
          if (!done.isCompleted) done.complete(addr);
          return;
        }
        final (problem, outcome) = switch (resp.statusCode) {
          401 => (LaunchpadProblem.notPaired, 'not paired (HTTP 401)'),
          429 => (LaunchpadProblem.blocked, 'refusing for now (HTTP 429)'),
          final code => (LaunchpadProblem.unreachable, 'unexpected answer (HTTP $code)'),
        };
        failed(i, LaunchpadException(problem), outcome);
      } on Object catch (e) {
        final wrong = mismatched?.call() == true && (e is HandshakeException || e is TlsException);
        failed(
          i,
          LaunchpadException(wrong ? LaunchpadProblem.wrongCertificate : LaunchpadProblem.unreachable, e),
          describeFailure(e, mismatched: wrong),
        );
      }
    }();
  }
  return done.future;
}

/// Pairs with the launchpad behind [invitation], returning the new home.
Future<Home> pairWithLaunchpad(PairingInvitation invitation, {required String deviceName}) async {
  var mismatch = false;
  final client = pinnedHttpClient(invitation.fingerprint, onMismatch: () => mismatch = true);
  try {
    final addr = await findLaunchpad(client, invitation.addresses,
        relays: invitation.relays, mismatched: () => mismatch);
    final rq = await client.postUrl(Uri.parse('https://$addr/api/pair'));
    rq.headers.contentType = ContentType.json;
    rq.write(jsonEncode({'code': invitation.code, 'name': deviceName}));
    final resp = await rq.close().timeout(const Duration(seconds: 15));
    final body = await utf8.decodeStream(resp);
    switch (resp.statusCode) {
      case 200:
        final j = jsonDecode(body) as Map<String, dynamic>;
        final name = j['name'] as String?;
        return Home(
          name: name == null || name.isEmpty ? invitation.name : name,
          fingerprint: invitation.fingerprint,
          token: j['token'] as String,
          addresses: invitation.addresses,
          relays: invitation.relays,
          deviceId: (j['device'] as Map<String, dynamic>)['id'] as String,
        );
      case 403:
        throw const LaunchpadException(LaunchpadProblem.badCode);
      case 429:
        throw const LaunchpadException(LaunchpadProblem.blocked);
      default:
        throw LaunchpadException(LaunchpadProblem.unreachable, 'HTTP ${resp.statusCode}');
    }
  } on LaunchpadException {
    rethrow;
  } on Object catch (e) {
    throw LaunchpadException(mismatch ? LaunchpadProblem.wrongCertificate : LaunchpadProblem.unreachable, e);
  } finally {
    client.close(force: true);
  }
}
