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

  Stream<SsdpMessage> get messages => _controller.stream;

  /// Set when the OS refuses multicast with "no route to host", which on
  /// Apple platforms means the user hasn't allowed Local Network access.
  bool localNetworkDenied = false;

  /// Opens one socket per IPv4 interface so that searches go out on every
  /// network (Wi-Fi and Ethernet on a desktop, for example), and joins the
  /// multicast group to hear NOTIFY announcements.
  Future<void> start() async {
    final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        try {
          final s = await RawDatagramSocket.bind(addr, 0);
          s.multicastHops = 4;
          _setMulticastInterface(s, addr);
          s.listen((event) => _onEvent(s, event), onError: _onSocketError);
          _sockets.add(s);
        } on SocketException {
          // Interface went away or doesn't allow binding; skip it.
        }
      }
    }
    try {
      final l = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port,
          reuseAddress: true, reusePort: !Platform.isWindows && !Platform.isAndroid);
      for (final iface in interfaces) {
        try {
          l.joinMulticast(_group, iface);
        } on Object {
          // Already joined through another address, or not permitted.
        }
      }
      l.listen((event) => _onEvent(l, event), onError: _onSocketError);
      _listener = l;
    } on Object {
      // Port 1900 may be taken or multicast receive not permitted (iOS
      // without the multicast entitlement). Searching still works.
    }
  }

  /// Sends M-SEARCH for media servers and renderers on every interface.
  /// Each request is sent twice because UDP may drop either.
  Future<void> search({int mx = 2}) async {
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
            s.send(utf8.encode(msg), _group, _port);
          } on SocketException {
            // Network changed under us; the next search will rebind.
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// Sets IP_MULTICAST_IF so the search leaves through this interface; the
  /// OS otherwise picks one route for the whole multicast group.
  static void _setMulticastInterface(RawDatagramSocket s, InternetAddress addr) {
    final option = Platform.isLinux || Platform.isAndroid ? 32 : 9;
    try {
      s.setRawOption(RawSocketOption(
          RawSocketOption.levelIPv4, option, Uint8List.fromList(addr.rawAddress)));
    } on Object {
      // Unsupported here; binding to the address usually suffices.
    }
  }

  /// Send failures arrive asynchronously on the socket stream. On macOS and
  /// iOS, EHOSTUNREACH here usually means Local Network access was denied.
  void _onSocketError(Object error) {
    if (error is SocketException && error.osError?.errorCode == 65) {
      localNetworkDenied = true;
    }
  }

  void _onEvent(RawDatagramSocket s, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? d;
    while ((d = s.receive()) != null) {
      final msg = SsdpMessage.parse(d!.data, d.address);
      if (msg != null) _controller.add(msg);
    }
  }

  Future<void> stop() async {
    for (final s in _sockets) {
      s.close();
    }
    _sockets.clear();
    _listener?.close();
    _listener = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
