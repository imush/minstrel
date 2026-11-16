import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A parsed SSDP message: an M-SEARCH response or a NOTIFY announcement.
class SsdpMessage {
  final Map<String, String> headers;
  final InternetAddress from;

  SsdpMessage(this.headers, this.from);

  Uri? get location {
    final l = headers['location'];
    return l == null ? null : Uri.tryParse(l);
  }

  /// ST for search responses, NT for notifications.
  String? get target => headers['st'] ?? headers['nt'];
  String? get usn => headers['usn'];
  bool get isByeBye => headers['nts'] == 'ssdp:byebye';

  /// The device UDN, taken from USN (`uuid:...::urn:...`).
  String? get udn => usn?.split('::').first;

  static SsdpMessage? parse(List<int> data, InternetAddress from) {
    final text = utf8.decode(data, allowMalformed: true);
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.isEmpty) return null;
    final start = lines.first.toUpperCase();
    if (!start.startsWith('HTTP/1.1 200') && !start.startsWith('NOTIFY')) {
      return null; // other control points' M-SEARCH requests
    }
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      headers[line.substring(0, colon).trim().toLowerCase()] =
          line.substring(colon + 1).trim();
    }
    return SsdpMessage(headers, from);
  }
}

/// SSDP search and listen. Multicast never leaves the local network, so this
/// only finds devices on the LAN; remote servers are added by URL instead.
class SsdpClient {
  static final _group = InternetAddress('239.255.255.250');
  static const _port = 1900;

  static const searchTargets = [
    'urn:schemas-upnp-org:device:MediaServer:1',
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:av-openhome-org:service:Product:1',
  ];

  final _controller = StreamController<SsdpMessage>.broadcast();
  final List<RawDatagramSocket> _sockets = [];
  RawDatagramSocket? _listener;

  /// The interface addresses the sockets were opened on.
  Set<String> _bound = const {};

  Stream<SsdpMessage> get messages => _controller.stream;

  /// Set when the OS refuses even a direct (unicast) packet to the local
  /// network: on Apple platforms, the user hasn't allowed Local Network
  /// access. Each search starts by assuming it is allowed again: on iOS the
  /// first search usually goes out while the permission prompt is showing.
  bool localNetworkDenied = false;

  /// Set when the OS refuses the multicast search but lets a direct packet
  /// through: Local Network access is allowed, but iOS keeps multicast for
  /// apps with Apple's multicast entitlement. Devices are then found only
  /// at addresses already known.
  bool multicastBlocked = false;

  /// A search was refused with "no route to host"; which of the two it was
  /// is told apart after the search.
  bool _refused = false;

  /// What happened to the sockets and searches, newest last, for the
  /// diagnostics page: discovery fails silently by design, so without this
  /// a device that finds nothing can't say why.
  final log = <String>[];
  static const _logMost = 80;

  /// Replies and announcements heard, by sender address.
  final heard = <String, int>{};
  bool _searchWorked = false;

  void _note(String line) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    log.add('$t $line');
    if (log.length > _logMost) log.removeRange(0, log.length - _logMost);
  }

  /// Opens one socket per IPv4 interface so that searches go out on every
  /// network (Wi-Fi and Ethernet on a desktop, for example), and joins the
  /// multicast group to hear NOTIFY announcements.
  Future<void> start() async {
    final interfaces = await _interfaces();
    _bound = _addressesOf(interfaces);
    _note('start: interfaces ${_addressesOf(interfaces).join(', ')}');
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        try {
          final s = await RawDatagramSocket.bind(addr, 0);
          s.multicastHops = 4;
          final how = _setMulticastInterface(s, addr);
          s.listen((event) => _onEvent(s, event), onError: _onSocketError);
          _sockets.add(s);
          _note('bound ${addr.address}:${s.port}${how == null ? '' : ' (multicast interface: $how)'}');
        } on SocketException catch (e) {
          // Interface went away or doesn't allow binding; skip it.
          _note('bind ${addr.address} failed: ${_short(e)}');
        }
      }
    }
    try {
      final l = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port,
          reuseAddress: true, reusePort: !Platform.isWindows && !Platform.isAndroid);
      for (final iface in interfaces) {
        try {
          l.joinMulticast(_group, iface);
          _note('listening on 1900, joined on ${iface.name}');
        } on Object catch (e) {
          // Already joined through another address, or not permitted.
          _note('join on ${iface.name} failed: ${_short(e)}');
        }
      }
      l.listen((event) => _onEvent(l, event), onError: _onSocketError);
      _listener = l;
    } on Object catch (e) {
      // Port 1900 may be taken or multicast receive not permitted (iOS
      // without the multicast entitlement). Searching still works.
      _note('listen on 1900 failed: ${_short(e)}');
    }
  }

  /// Whether the device's addresses changed since the sockets were opened:
  /// it joined or left a network.
  Future<bool> networkChanged() async => !_sameAddresses(_addressesOf(await _interfaces()), _bound);

  /// Sends M-SEARCH for media servers and renderers on every interface.
  /// Each request is sent twice because UDP may drop either.
  Future<void> search({int mx = 2}) async {
    // Sockets belong to the network they were opened on: after leaving
    // Wi-Fi and coming back (or any change of address) they no longer
    // reach it, so open them again.
    if (!_sameAddresses(_addressesOf(await _interfaces()), _bound)) {
      await stop();
      await start();
    }
    _refused = false;
    var sent = 0, failed = 0;
    if (_sockets.isEmpty) _note('search: no socket to send from');
    for (var round = 0; round < 2; round++) {
      for (final s in _sockets) {
        for (final st in searchTargets) {
          final msg = 'M-SEARCH * HTTP/1.1\r\n'
              'HOST: 239.255.255.250:1900\r\n'
              'MAN: "ssdp:discover"\r\n'
              'MX: $mx\r\n'
              'ST: $st\r\n'
              'USER-AGENT: minstrel/0.1 UPnP/1.1\r\n\r\n';
          try {
            if (s.send(utf8.encode(msg), _group, _port) > 0) {
              sent++;
            } else {
              failed++;
              if (round == 0) _note('send from ${s.address.address} wrote nothing');
            }
          } on SocketException catch (e) {
            // Refused, or the network changed under us; the next search
            // reopens the sockets.
            failed++;
            if (round == 0) _note('send from ${s.address.address} failed: ${_short(e)}');
            _onSocketError(e);
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    // Every failed search, but a working one only once: the background
    // search would otherwise push everything else out of the log.
    if (failed > 0 || sent == 0 || !_searchWorked) {
      _note('search: sent $sent, failed $failed${_refused ? ' (refused)' : ''}');
      _searchWorked = failed == 0 && sent > 0;
    }
    if (!_refused) {
      localNetworkDenied = multicastBlocked = false;
    } else if (_sockets.isNotEmpty) {
      final denied = await _unicastRefused(_sockets.first.address);
      localNetworkDenied = denied;
      multicastBlocked = !denied;
    }
  }

  /// Sends one datagram straight to another address on the network (the
  /// discard port of the usual router address), to see whether the OS
  /// refuses the local network as a whole or only multicast.
  static Future<bool> _unicastRefused(InternetAddress local) async {
    final b = local.rawAddress;
    final to = InternetAddress.fromRawAddress(Uint8List.fromList([b[0], b[1], b[2], b[3] == 1 ? 2 : 1]));
    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(local, 0);
      final refused = Completer<bool>();
      s.listen((_) {}, onError: (Object e) {
        if (!refused.isCompleted) refused.complete(_isRefusal(e));
      });
      try {
        s.send(const [0], to, 9);
      } on SocketException catch (e) {
        return _isRefusal(e);
      }
      return await refused.future.timeout(const Duration(milliseconds: 500), onTimeout: () => false);
    } on Object {
      return false;
    } finally {
      s?.close();
    }
  }

  static bool _isRefusal(Object e) => e is SocketException && e.osError?.errorCode == 65;

  static Future<List<NetworkInterface>> _interfaces() async {
    try {
      final all = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      return all.where(_isLan).toList();
    } on Object {
      return const [];
    }
  }

  /// On Apple platforms, Wi-Fi and Ethernet are en*, and a shared hotspot is
  /// bridge*. The rest (cellular pdp_ip*, VPN utun* and ipsec*, AirDrop's
  /// awdl* and llw*) never have UPnP devices, and refuse multicast with the
  /// same "no route to host" as a missing Local Network permission.
  static bool _isLan(NetworkInterface i) =>
      !(Platform.isIOS || Platform.isMacOS) || i.name.startsWith('en') || i.name.startsWith('bridge');

  static Set<String> _addressesOf(List<NetworkInterface> interfaces) =>
      {for (final i in interfaces) for (final a in i.addresses) '${i.name}/${a.address}'};

  static bool _sameAddresses(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

  /// Sets IP_MULTICAST_IF so the search leaves through this interface; the
  /// OS otherwise picks one route for the whole multicast group. Returns
  /// why it couldn't, or null.
  static String? _setMulticastInterface(RawDatagramSocket s, InternetAddress addr) {
    final option = Platform.isLinux || Platform.isAndroid ? 32 : 9;
    try {
      s.setRawOption(RawSocketOption(
          RawSocketOption.levelIPv4, option, Uint8List.fromList(addr.rawAddress)));
      return null;
    } on Object catch (e) {
      // Unsupported here; binding to the address usually suffices.
      return _short(e);
    }
  }

  static String _short(Object e) => e is SocketException
      ? '${e.osError?.message ?? e.message} (errno ${e.osError?.errorCode})'
      : e.toString().split('\n').first;

  /// Send failures may also arrive asynchronously on the socket stream. On
  /// macOS and iOS, EHOSTUNREACH means the OS refused: see [search].
  void _onSocketError(Object error) {
    _note('socket error: ${_short(error)}');
    if (_isRefusal(error)) _refused = true;
  }

  void _onEvent(RawDatagramSocket s, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? d;
    while ((d = s.receive()) != null) {
      final msg = SsdpMessage.parse(d!.data, d.address);
      if (msg != null) {
        final from = d.address.address;
        if (!heard.containsKey(from)) {
          _note('first ${msg.headers.containsKey('nt') ? 'announcement' : 'reply'} from $from (${msg.target})');
        }
        heard[from] = (heard[from] ?? 0) + 1;
        localNetworkDenied = multicastBlocked = false;
        _controller.add(msg);
      }
    }
  }

  Future<void> stop() async {
    for (final s in _sockets) {
      s.close();
    }
    _sockets.clear();
    _listener?.close();
    _listener = null;
    _bound = const {};
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
