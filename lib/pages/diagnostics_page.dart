import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../app_services.dart';

/// A report of what the app's networking is doing, for sending to the
/// developer: discovery and the home proxy both fail quietly by design, so
/// a device that finds nothing otherwise can't say why.
///
/// Runs a few tests of its own on opening: a fresh loopback server, the
/// home proxy's listener, and a search from new sockets.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  final _app = AppServices.instance;
  String? _report;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => _report = null);
    final report = await _build();
    if (mounted) setState(() => _report = report);
  }

  Future<String> _build() async {
    final out = StringBuffer();
    void section(String title) => out.writeln('\n== $title');

    final info = await PackageInfo.fromPlatform();
    out.writeln('Minstrel ${info.version} (${info.buildNumber})');
    out.writeln('${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    out.writeln(DateTime.now().toIso8601String());

    section('Interfaces');
    try {
      for (final i in await NetworkInterface.list(includeLoopback: true, includeLinkLocal: true)) {
        out.writeln('${i.name}: ${i.addresses.map((a) => a.address).join(', ')}');
      }
    } on Object catch (e) {
      out.writeln('could not list: $e');
    }

    section('Loopback');
    out.writeln('fresh server: ${await _loopbackTest()}');
    final proxy = _app.homes.proxy;
    out.writeln('home proxy on ${proxy.port}: ${await proxy.probe() ?? 'answers'}');
    out.writeln('home proxy over HTTP: ${await _httpTest(proxy.port)}');
    for (final l in proxy.log) {
      out.writeln('  $l');
    }

    section('Homes');
    for (final h in _app.homes.homes) {
      final status = _app.homes.status(h);
      out.writeln('${h.name}: ${status.state.name}${status.atHome ? ', at home' : ''}');
      for (final t in status.tried) {
        out.writeln('  tried $t');
      }
      for (final t in _app.homes.trouble(h)) {
        out.writeln('  $t');
      }
    }

    section('Search');
    // From new sockets, so the result says what a search does now rather
    // than what the ones opened at start did.
    await _app.registry.reopen();
    await Future<void>.delayed(const Duration(seconds: 4));
    final registry = _app.registry;
    out.writeln('local network denied: ${registry.localNetworkDenied}, '
        'multicast blocked: ${registry.multicastBlocked}');
    for (final l in registry.ssdpLog) {
      out.writeln('  $l');
    }
    out.writeln('heard: ${registry.ssdpHeard.entries.map((e) => '${e.key} ×${e.value}').join(', ')}');

    section('Servers listed');
    for (final s in registry.servers) {
      out.writeln('${s.name}: ${s.device.location}${s.via == null ? '' : ' (via ${s.via})'}');
    }
    section('Players listed');
    for (final r in registry.renderers) {
      out.writeln(r.name);
    }
    return out.toString().trim();
  }

  /// A loopback server of its own, asked over plain HTTP: whether this
  /// device lets the app talk to itself at all, apart from the proxy.
  static Future<String> _loopbackTest() async {
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) => r.response
        ..write('ok')
        ..close());
      return '${server.port}: ${await _httpTest(server.port)}';
    } on Object catch (e) {
      return 'could not listen: $e';
    } finally {
      await server?.close(force: true);
    }
  }

  static Future<String> _httpTest(int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final rq = await client.get('127.0.0.1', port, '/');
      final rs = await rq.close().timeout(const Duration(seconds: 3));
      await rs.drain<void>();
      return 'HTTP ${rs.statusCode}';
    } on Object catch (e) {
      return '$e';
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Network diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Run again',
            icon: const Icon(Icons.refresh),
            onPressed: report == null ? null : _run,
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: report == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: report));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Copied')));
                  },
          ),
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Share',
              icon: const Icon(Icons.ios_share),
              onPressed: report == null
                  ? null
                  : () {
                      final box = context.findRenderObject() as RenderBox?;
                      SharePlus.instance.share(ShareParams(
                        text: report,
                        subject: 'Minstrel network diagnostics',
                        // Where the iPad's share sheet points from.
                        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
                      ));
                    },
            ),
          ),
        ],
      ),
      body: report == null
          ? const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Testing the network…'),
              ]),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                report,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
    );
  }
}
