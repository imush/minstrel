import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'launchpad.dart';

enum HomeState { connecting, connected, unreachable, notPaired }

class HomeStatus {
  final HomeState state;

  /// The launchpad address in use, when connected.
  final String? address;
  final LaunchpadProblem? problem;

  /// When unreachable: each address tried and what happened there.
  final List<String> tried;

  /// Connected through a satellite rather than directly.
  final bool viaSatellite;

  const HomeStatus(this.state, {this.address, this.problem, this.tried = const [], this.viaSatellite = false});

  /// Whether the address in use is IPv6. Written `[host]:port`, so the
  /// brackets come off before parsing.
  bool get isIPv6 {
    final host = address == null ? null : Uri.tryParse('https://$address')?.host;
    final ip = host == null ? null : InternetAddress.tryParse(host);
    return ip != null && ip.type == InternetAddressType.IPv6;
  }

  /// Connected over the home network rather than from outside.
  bool get atHome {
    final host = address == null ? null : Uri.tryParse('https://$address')?.host;
    final ip = host == null ? null : InternetAddress.tryParse(host);
    if (ip == null || ip.type != InternetAddressType.IPv4) return false;
    final b = ip.rawAddress;
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
  }
}

/// A local HTTP server that makes paired homes look like LAN servers to the
/// rest of the app: `http://127.0.0.1:<port>/h/<home id>/...` is relayed to
/// that home's launchpad over pinned HTTPS, with the device's token.
///
/// The launchpad rewrites URLs straight into this loopback form, so browsing,
/// SOAP, album art and the audio player all work with plain local URLs, and
/// keep working when the phone moves between home Wi-Fi and the outside.
///
/// Audio downloads survive dropped connections: when the link breaks
/// mid-file, the proxy reconnects (on whichever address answers) and asks
/// for the rest with a Range request, so the player sees a pause, not an
/// error.
///
/// A loopback URL is reachable only by this device, so a renderer on the
/// LAN can't play from a home. [openRelay] adds a second listener on one of
/// this device's LAN addresses, where the same homes are served as
/// `http://<lan ip>:<port>/r/<token>/h/<home id>/...`. That listener is
/// open to everyone on that network, so it is deliberately narrow: an
/// unguessable token, GET and HEAD only, and only the paths [allowRelay]
/// names.
class HomeProxy {
  /// Used when free, so saved queues keep working across app runs.
  static const preferredPort = 47380;

  /// How long a broken download keeps trying before giving up.
  final Duration maxOutage;

  HomeProxy({this.maxOutage = const Duration(minutes: 2)});

  HttpServer? _server;
  final _links = <String, _Link>{};

  /// The compression profile to ask launchpads for (`aac-192` and so on),
  /// or null for the original files. Only for this device's own playback
  /// away from home: at home the phone reaches the servers directly.
  String? compression;
  final _changes = StreamController<String>.broadcast();

  /// Ids of homes whose status changed.
  Stream<String> get changes => _changes.stream;

  int get port => _server!.port;

  Future<void> start({int port = preferredPort}) async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server!
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 30)
      ..listen(_handle);
  }

  _Relay? _relay;

  /// Whether a renderer on the LAN can currently fetch home tracks through
  /// this device.
  bool get relaying => _relay != null;

  /// Opens the relay listener on [address], one of this device's own LAN
  /// addresses, and returns the base for relay URLs. Null when it can't
  /// bind. Each session gets a fresh token, so URLs from an earlier one
  /// stop working.
  Future<Uri?> openRelay(InternetAddress address) async {
    await closeRelay();
    final HttpServer server;
    try {
      server = await HttpServer.bind(address, 0);
    } on SocketException {
      return null;
    }
    server
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 30)
      ..listen(_handle);
    final relay = _relay = _Relay(server, _newToken());
    return relay.base;
  }

  Future<void> closeRelay() async {
    final relay = _relay;
    _relay = null;
    await relay?.server.close(force: true);
  }

  /// The relay URL for a loopback home URL, or null when the relay isn't
  /// open. The URL still has to be named by [allowRelay] to be served.
  Uri? relayFor(Uri homeUrl) {
    final relay = _relay;
    if (relay == null || !isHomeUrl(homeUrl)) return null;
    final query = homeUrl.hasQuery ? '?${homeUrl.query}' : '';
    return Uri.parse('${relay.base}${homeUrl.path}$query');
  }

  /// Limits the relay to the tracks of the current queue, given as the
  /// relay URLs handed to the renderer. A renderer never needs more than
  /// what is queued, so a token that leaks exposes only that, not the
  /// library.
  void allowRelay(Iterable<Uri> relayUrls) {
    final relay = _relay;
    if (relay == null) return;
    relay.allowed = {for (final u in relayUrls) if (isRelayUrl(u)) _relayedPath(u)};
  }

  /// Whether [uri] is one of this proxy's relay URLs.
  static bool isRelayUrl(Uri uri) {
    final seg = uri.pathSegments;
    return seg.length >= 3 && seg[0] == 'r' && seg[2] == 'h';
  }

  /// The home path a relay URL stands for: `/r/<token>/h/x/u/y` → `/h/x/u/y`.
  static String _relayedPath(Uri uri) {
    final prefix = '/r/${uri.pathSegments[1]}';
    final path = uri.path.startsWith(prefix) ? uri.path.substring(prefix.length) : uri.path;
    return uri.hasQuery ? '$path?${uri.query}' : path;
  }

  static String _newToken() {
    final rnd = Random.secure();
    return base64Url.encode(List<int>.generate(16, (_) => rnd.nextInt(256))).replaceAll('=', '');
  }

  /// Compares in constant time, so a wrong token tells nothing by how long
  /// it took to reject.
  static bool _sameToken(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  void add(Home home) {
    _links.remove(home.id)?.close();
    _links[home.id] = _Link(home, () => _changes.add(home.id));
  }

  /// Takes new addresses for a home already added, without dropping
  /// downloads in progress.
  void update(Home home) {
    final link = _links[home.id];
    if (link == null) return add(home);
    link.home = home;
  }

  void remove(String id) => _links.remove(id)?.close();

  /// Finds the best address again on the next request, after the network
  /// may have changed (arriving home, leaving it). Transfers under way keep
  /// their connection.
  void recheck() {
    for (final l in _links.values) {
      l.recheck();
    }
  }

  HomeStatus status(String id) => _links[id]?.status ?? const HomeStatus(HomeState.unreachable);

  /// The loopback base for a home's URLs.
  Uri base(String id) => Uri.parse('http://127.0.0.1:$port/h/$id');

  /// Points a saved URL (from an earlier run, maybe on another port) at
  /// this proxy. A saved relay URL comes back as a loopback one: its token
  /// and the address it was served on are both gone, and this device can
  /// always play it itself.
  Uri rehome(Uri uri) {
    if (isRelayUrl(uri)) return Uri.parse('http://127.0.0.1:$port${_relayedPath(uri)}');
    return uri.host == '127.0.0.1' && uri.pathSegments.firstOrNull == 'h' && uri.port != port
        ? uri.replace(port: port)
        : uri;
  }

  /// Whether [uri] reaches a home through this proxy (so only this device
  /// can fetch it: a renderer can't).
  static bool isHomeUrl(Uri uri) => uri.host == '127.0.0.1' && uri.pathSegments.firstOrNull == 'h';

  /// Connects to a home and lists its media servers.
  Future<LaunchpadInfo> info(String id) async {
    final link = _links[id];
    if (link == null) throw const LaunchpadException(LaunchpadProblem.notPaired);
    final resp = await link.send('GET', '/api/info', const {}, null, base(id));
    final body = await utf8.decodeStream(resp);
    if (resp.statusCode != 200) throw LaunchpadException(_problemFor(resp) ?? LaunchpadProblem.unreachable);
    final info = LaunchpadInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    link.transcode = info.transcode;
    return info;
  }

  /// A launchpad API request: [body] is sent as JSON, and the answer
  /// decoded from JSON (null when empty). A refusal throws an
  /// [HttpException] with the launchpad's explanation.
  Future<Object?> api(String id, String method, String path, [Object? body]) async {
    final link = _links[id];
    if (link == null) throw const LaunchpadException(LaunchpadProblem.notPaired);
    final resp = await link.send(
      method,
      path,
      body == null ? const {} : {'content-type': ['application/json']},
      body == null ? null : utf8.encode(jsonEncode(body)),
      base(id),
    );
    final text = await utf8.decodeStream(resp);
    if (resp.statusCode == 401) throw const LaunchpadException(LaunchpadProblem.notPaired);
    if (resp.statusCode >= 300) throw HttpException(text.trim().isEmpty ? 'HTTP ${resp.statusCode}' : text.trim());
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// Whether home [id]'s launchpad can compress, as of its last answer.
  bool canCompress(String id) => _links[id]?.transcode.isNotEmpty ?? false;

  Future<void> close() async {
    for (final l in _links.values) {
      l.close();
    }
    _links.clear();
    await closeRelay();
    await _server?.close(force: true);
    await _changes.close();
  }

  static const _hopByHop = {
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer',
    'transfer-encoding', 'upgrade', 'host', 'content-length', 'accept-encoding', 'authorization',
  };

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    var started = false;
    try {
      final relay = _relay;
      final onRelay = relay != null && req.connectionInfo?.localPort == relay.server.port;
      // The loopback listener is this device only; the relay listener is
      // open to a whole network, so it is checked before anything else.
      var local = req.uri.path;
      if (onRelay) {
        if (req.method != 'GET' && req.method != 'HEAD') {
          return _deny(res, HttpStatus.methodNotAllowed);
        }
        final seg = req.uri.pathSegments;
        // A renderer can't send an Authorization header, so the capability
        // is the URL itself. A wrong one gets the same bare 404 as a
        // nonexistent path, so scanners learn nothing.
        if (seg.length < 3 || seg[0] != 'r' || !_sameToken(seg[1], relay.token)) {
          return _deny(res, HttpStatus.notFound);
        }
        local = local.substring('/r/${seg[1]}'.length);
        final asked = req.uri.hasQuery ? '$local?${req.uri.query}' : local;
        if (!relay.allowed.contains(asked)) return _deny(res, HttpStatus.notFound);
      } else if (req.uri.pathSegments.firstOrNull == 'r') {
        // Relay URLs are not served on loopback: they carry no home id of
        // their own until the prefix is checked above.
        return _deny(res, HttpStatus.notFound);
      }
      final seg = local.split('/')..removeWhere((s) => s.isEmpty);
      final link = seg.length >= 2 && seg[0] == 'h' ? _links[seg[1]] : null;
      if (link == null) return _deny(res, HttpStatus.notFound);
      final prefix = '/h/${seg[1]}';
      var path = local.substring(prefix.length);
      if (path.isEmpty) path = '/';
      if (req.uri.hasQuery) path += '?${req.uri.query}';
      final body = req.method == 'GET' || req.method == 'HEAD'
          ? null
          : await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final headers = <String, List<String>>{};
      req.headers.forEach((k, v) {
        if (!_hopByHop.contains(k)) headers[k] = v;
      });

      final base = this.base(seg[1]);
      final profile = compression;
      // Not for a renderer: the metadata it was given names the original
      // format, and a player handed AAC under an audio/flac label rejects
      // it. Compression is for this device's own playback.
      if (profile != null &&
          !onRelay &&
          req.method == 'GET' &&
          path.startsWith('/u/') &&
          !link.status.atHome &&
          link.transcode.contains(profile)) {
        headers['x-minstrel-transcode'] = [profile];
      }
      final up = await link.send(req.method, path, headers, body, base);
      res.statusCode = up.statusCode;
      up.headers.forEach((k, v) {
        if (!_hopByHop.contains(k)) {
          for (final x in v) {
            res.headers.add(k, x, preserveHeaderCase: true);
          }
        }
      });
      res.contentLength = up.contentLength;
      started = true;
      if (req.method == 'HEAD') {
        await up.drain<void>();
      } else {
        await res.addStream(_resumable(link, path, headers, up, base, req.method));
      }
      await res.close();
    } on LaunchpadException catch (e) {
      if (started) return _abort(res);
      res.statusCode = e.problem == LaunchpadProblem.notPaired ? 401 : HttpStatus.gatewayTimeout;
      res.headers.set('X-Launchpad-Error', e.problem.name);
      res.write(e);
      await res.close();
    } on Object {
      // The player hung up (seek, skip) or the stream broke for good.
      await _abort(res);
    }
  }

  static Future<void> _deny(HttpResponse res, int status) async {
    res.statusCode = status;
    await res.close();
  }

  static Future<void> _abort(HttpResponse res) async {
    try {
      await res.close();
    } on Object {
      // already gone
    }
  }

  /// The body of [first], reconnecting from where it broke off when the
  /// response supports byte ranges, or is a compressed stream: the
  /// launchpad carries on converting when the phone drops out, so asking
  /// again gets the same stream, from the cache once it is done, and the
  /// part already played is skipped.
  Stream<List<int>> _resumable(_Link link, String path, Map<String, List<String>> headers,
      HttpClientResponse first, Uri base, String method) async* {
    final span = method == 'GET' ? _Span.of(first) : null;
    final converted = method == 'GET' && first.statusCode == HttpStatus.ok &&
        first.headers.value('x-minstrel-transcoded') != null;
    if (span == null && !converted) {
      yield* first;
      return;
    }
    var pos = span?.start ?? 0;
    final end = span?.end;
    HttpClientResponse? current = first;
    var skip = 0; // bytes of a restarted stream already passed on
    DateTime? outage;
    var delay = const Duration(milliseconds: 500);
    while (end == null || pos <= end) {
      if (current == null) {
        final since = outage ??= DateTime.now();
        if (DateTime.now().difference(since) > maxOutage) {
          throw const LaunchpadException(LaunchpadProblem.unreachable);
        }
        await Future<void>.delayed(delay);
        delay = Duration(milliseconds: min(delay.inMilliseconds * 2, 8000));
        try {
          final range = end == null ? 'bytes=$pos-' : 'bytes=$pos-$end';
          final r = await link.send('GET', path, {...headers, 'range': [range]}, null, base);
          if (r.statusCode == HttpStatus.partialContent && _Span.of(r)?.start == pos) {
            current = r;
            skip = 0;
          } else if (end == null && r.statusCode == HttpStatus.ok && r.headers.value('x-minstrel-transcoded') != null) {
            // Converting again from the start; pass over what was played.
            current = r;
            skip = pos;
          } else {
            await r.drain<void>();
            continue;
          }
        } on Object {
          continue;
        }
      }
      try {
        await for (var chunk in current) {
          if (skip > 0) {
            if (chunk.length <= skip) {
              skip -= chunk.length;
              continue;
            }
            chunk = chunk.sublist(skip);
            skip = 0;
          }
          pos += chunk.length;
          outage = null;
          delay = const Duration(milliseconds: 500);
          yield chunk;
        }
        // A compressed stream's length is known only when it ends.
        if (end == null && skip == 0) return;
      } on Object {
        // Connection dropped mid-file; resume below.
      }
      current = null;
    }
  }
}

/// The relay listener: one session, one token, one set of allowed paths.
class _Relay {
  final HttpServer server;
  final String token;

  /// Paths of the tracks currently queued; nothing else is served.
  Set<String> allowed = const {};

  _Relay(this.server, this.token);

  Uri get base => Uri.parse('http://${server.address.address}:${server.port}/r/$token');
}

/// Of [candidates], this device's address on the same network as [peer]:
/// the one sharing the longest prefix with it.
///
/// Guesswork, necessarily. Dart exposes no netmasks, and a connected
/// socket's `address` is the peer rather than the local end, so there is no
/// way to ask which address would be used. Requiring the first two octets
/// to match is what stops a cellular or VPN address being offered to a
/// player on the Wi-Fi.
InternetAddress? addressNearest(InternetAddress peer, Iterable<InternetAddress> candidates) {
  if (peer.type != InternetAddressType.IPv4) return null;
  InternetAddress? best;
  var bestBits = 0;
  for (final a in candidates) {
    if (a.type != InternetAddressType.IPv4 || a.isLoopback) continue;
    final bits = _commonPrefixBits(a.rawAddress, peer.rawAddress);
    if (bits > bestBits) {
      bestBits = bits;
      best = a;
    }
  }
  return bestBits >= 16 ? best : null;
}

int _commonPrefixBits(List<int> a, List<int> b) {
  var n = 0;
  for (var i = 0; i < 4; i++) {
    final diff = a[i] ^ b[i];
    if (diff == 0) {
      n += 8;
      continue;
    }
    for (var bit = 7; bit >= 0 && (diff >> bit) & 1 == 0; bit--) {
      n++;
    }
    break;
  }
  return n;
}

/// This device's own address on the network it reaches [target] by. Null
/// when the target isn't an IPv4 address on a network this device is on:
/// the relay serves IPv4 LANs, which is what renderers speak.
Future<InternetAddress?> localAddressToward(Uri target) async {
  try {
    final peer = InternetAddress.tryParse(target.host) ??
        (await InternetAddress.lookup(target.host, type: InternetAddressType.IPv4)).firstOrNull;
    if (peer == null) return null;
    final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return addressNearest(peer, [for (final i in ifaces) ...i.addresses]);
  } on Object {
    return null;
  }
}

LaunchpadProblem? _problemFor(HttpClientResponse r) {
  final kind = r.headers.value('x-launchpad-error');
  return switch (kind) {
    'server-unreachable' => LaunchpadProblem.serverUnreachable,
    'unknown-server' => LaunchpadProblem.unknownServer,
    _ => r.statusCode == 401
        ? LaunchpadProblem.notPaired
        : r.statusCode == 429
            ? LaunchpadProblem.blocked
            : null,
  };
}

/// The byte range a response covers, if it can be resumed.
class _Span {
  final int start;
  final int end; // inclusive

  const _Span(this.start, this.end);

  static _Span? of(HttpClientResponse r) {
    if (r.statusCode == HttpStatus.partialContent) {
      final m = RegExp(r'bytes (\d+)-(\d+)/').firstMatch(r.headers.value('content-range') ?? '');
      return m == null ? null : _Span(int.parse(m[1]!), int.parse(m[2]!));
    }
    final ranges = r.headers.value('accept-ranges')?.toLowerCase() ?? '';
    if (r.statusCode == HttpStatus.ok && ranges.contains('bytes') && r.contentLength > 0) {
      return _Span(0, r.contentLength - 1);
    }
    return null;
  }
}

/// One home's connection: which launchpad address works right now.
class _Link {
  Home home;
  final void Function() _changed;
  bool _mismatch = false;
  late final HttpClient _client = pinnedHttpClient(home.fingerprint, onMismatch: () => _mismatch = true);
  String? _address;
  DateTime? _probedAt;

  /// Compression profiles the launchpad offers.
  List<String> transcode = const [];
  Future<String>? _probing;
  HomeStatus status = const HomeStatus(HomeState.connecting);

  _Link(this.home, this._changed);

  void _set(HomeStatus s) {
    if (s.state == status.state &&
        s.address == status.address &&
        s.problem == status.problem &&
        s.viaSatellite == status.viaSatellite &&
        s.tried.join('\n') == status.tried.join('\n')) {
      return;
    }
    status = s;
    _changed();
  }

  void recheck() {
    if (_probing == null) _address = null;
  }

  Future<String> _connect() {
    final addr = _address;
    if (addr != null) {
      // Recheck now and then, to move to the LAN address on arriving home.
      final stale = DateTime.now().difference(_probedAt!) > const Duration(minutes: 2);
      if (stale && _probing == null && !status.atHome) unawaited(_probe().catchError((_) => addr));
      return Future.value(addr);
    }
    return _probe();
  }

  Future<String> _probe() => _probing ??= () async {
        _mismatch = false;
        try {
          final addr = await findLaunchpad(_client, home.addresses,
              relays: home.relays, token: home.token, mismatched: () => _mismatch);
          _address = addr;
          _probedAt = DateTime.now();
          _set(HomeStatus(HomeState.connected, address: addr, viaSatellite: home.relays.contains(addr)));
          return addr;
        } on LaunchpadException catch (e) {
          if (_address == null) {
            _set(HomeStatus(e.problem == LaunchpadProblem.notPaired ? HomeState.notPaired : HomeState.unreachable,
                problem: e.problem, tried: e.tried));
          }
          rethrow;
        } finally {
          _probing = null;
        }
      }();

  /// Sends a request to the launchpad, finding a working address first and
  /// trying again once on another if the connection fails.
  Future<HttpClientResponse> send(
      String method, String path, Map<String, List<String>> headers, List<int>? body, Uri base) async {
    for (var attempt = 0;; attempt++) {
      final addr = await _connect();
      try {
        final rq = await _client.openUrl(method, Uri.parse('https://$addr$path'));
        rq.followRedirects = false;
        headers.forEach(rq.headers.set);
        rq.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${home.token}');
        rq.headers.set('X-Minstrel-Base', base.toString());
        if (body != null) {
          rq.contentLength = body.length;
          rq.add(body);
        }
        final resp = await rq.close().timeout(const Duration(seconds: 60));
        if (resp.statusCode == 401) {
          _set(const HomeStatus(HomeState.notPaired, problem: LaunchpadProblem.notPaired));
        }
        return resp;
      } on Object catch (e) {
        if (!isConnectionError(e)) rethrow;
        _address = null;
        if (attempt >= 1) {
          final tried = ['$addr — ${describeFailure(e, mismatched: _mismatch)}'];
          _set(HomeStatus(HomeState.unreachable,
              problem: _mismatch ? LaunchpadProblem.wrongCertificate : LaunchpadProblem.unreachable,
              tried: tried));
          throw LaunchpadException(LaunchpadProblem.unreachable, e, tried);
        }
      }
    }
  }

  void close() => _client.close(force: true);
}
