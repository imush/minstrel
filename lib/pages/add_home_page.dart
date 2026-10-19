import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_services.dart';
import '../homes.dart';

/// Pairs with a minstrel-launchpad: scan the QR code it shows, open a
/// pairing file made on its console, or paste the link.
class AddHomePage extends StatefulWidget {
  const AddHomePage({super.key});

  @override
  State<AddHomePage> createState() => _AddHomePageState();
}

class _AddHomePageState extends State<AddHomePage> {
  final _link = TextEditingController();
  final _deviceName = TextEditingController(text: Homes.deviceName);
  PairingInvitation? _invitation;
  bool _pairing = false;
  String? _error;

  @override
  void dispose() {
    _link.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  void _use(String text) {
    final inv = PairingInvitation.parse(text);
    setState(() {
      _invitation = inv;
      _error = inv == null ? 'That isn\'t a Minstrel pairing link.' : null;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    _link.text = text;
    _use(text);
  }

  Future<void> _openFile() async {
    try {
      final file = await FilePicker.pickFile();
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final text = bytes.length > 8192 ? '' : utf8.decode(bytes, allowMalformed: true);
      _link.text = text.trim();
      _use(text);
      if (_invitation == null) setState(() => _error = 'That isn\'t a Minstrel pairing file.');
    } on Object catch (e) {
      setState(() => _error = 'Couldn\'t open the file: $e');
    }
  }

  Future<void> _pair() async {
    final inv = _invitation!;
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      final name = _deviceName.text.trim();
      final home = await AppServices.instance.homes
          .pair(inv, deviceName: name.isEmpty ? Homes.deviceName : name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Paired with ${home.name}')));
      Navigator.pop(context);
    } on LaunchpadException catch (e) {
      setState(() => _error = e.problem.message);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = _invitation;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Add home')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Pair with minstrel-launchpad to play your home\'s music from anywhere. '
            'Create an invitation on its console (port 7444 on the launchpad, from a browser at home), '
            'or run "minstrel-launchpad pair".',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          if (inv == null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 1,
                child: MobileScanner(
                  onDetect: (capture) {
                    for (final code in capture.barcodes) {
                      final v = code.rawValue;
                      if (v != null && PairingInvitation.parse(v) != null) {
                        _use(v);
                        return;
                      }
                    }
                  },
                  errorBuilder: (context, error) => ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('No camera available. Paste the link instead.',
                            textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _link,
              decoration: InputDecoration(
                labelText: 'Or the pairing link',
                hintText: 'minstrel://pair?…',
                suffixIcon: IconButton(
                    tooltip: 'Paste', icon: const Icon(Icons.content_paste), onPressed: _paste),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              onSubmitted: _use,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: _openFile,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Open pairing file'),
              ),
            ),
          ] else ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.home),
                title: Text(inv.name),
                subtitle: Text(inv.addresses.join('\n')),
                trailing: IconButton(
                  tooltip: 'Scan again',
                  icon: const Icon(Icons.close),
                  onPressed: _pairing ? null : () => setState(() => _invitation = null),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _deviceName,
              decoration: const InputDecoration(
                labelText: 'Name for this device',
                helperText: 'Shown in "minstrel-launchpad devices", to tell devices apart',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pairing ? null : _pair,
              icon: _pairing
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link),
              label: const Text('Pair'),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
