import 'dart:async';

import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:share_plus/share_plus.dart';

import '../app_services.dart';

/// Inviting people to a home, for a device the launchpad lets do so: from
/// anywhere, with a QR code to scan or a link to send. Invitations made here
/// only let people listen. Also lists every device paired with the home;
/// this device can revoke the ones it invited.
class SharingPage extends StatefulWidget {
  final Home home;

  const SharingPage({super.key, required this.home});

  @override
  State<SharingPage> createState() => _SharingPageState();
}

class _SharingPageState extends State<SharingPage> {
  HomeProxy get _proxy => AppServices.instance.homes.proxy;
  String get _id => widget.home.id;

  final _label = TextEditingController();
  var _valid = InvitationValidity.day;
  var _video = VideoReach.home;
  bool _creating = false;
  HomeInvitation? _created;

  List<HomeInvitation>? _pending;
  List<PairedDevice>? _devices;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final (pending, devices) = await (_proxy.invitations(_id), _proxy.pairedDevices(_id)).wait;
      if (!mounted) return;
      setState(() {
        _pending = pending;
        _devices = devices;
        _error = null;
      });
    } on ParallelWaitError<(List<HomeInvitation>?, List<PairedDevice>?), (AsyncError?, AsyncError?)> catch (e) {
      if (mounted) setState(() => _error = e.errors.$1?.error ?? e.errors.$2?.error);
    }
  }

  Future<void> _invite() async {
    setState(() => _creating = true);
    try {
      final inv = await _proxy.invite(_id,
          label: _label.text.trim(), valid: _valid, video: _video);
      _label.clear();
      setState(() => _created = inv);
      unawaited(_load());
    } on Object catch (e) {
      _snack('Couldn\'t create the invitation: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _send(HomeInvitation inv, BuildContext button) async {
    final box = button.findRenderObject() as RenderBox?;
    final who = inv.label == null ? '' : ' for ${inv.label}';
    await SharePlus.instance.share(ShareParams(
      subject: 'Listen to ${widget.home.name} with Minstrel',
      text: 'An invitation$who to listen to ${widget.home.name} with Minstrel. '
          'In the Minstrel app, tap Add home and paste this link. '
          'It works once, until ${_when(inv.expires)}.\n\n${inv.uri}',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  Future<void> _cancel(HomeInvitation inv) async {
    try {
      await _proxy.cancelInvitation(_id, inv.id);
      if (_created?.id == inv.id) setState(() => _created = null);
      await _load();
    } on Object catch (e) {
      _snack('Couldn\'t cancel it: $e');
    }
  }

  Future<void> _revoke(PairedDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: Text('It will no longer reach ${widget.home.name}. To come back, it needs a new invitation.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _proxy.revokeDevice(_id, d.id);
      await _load();
    } on Object catch (e) {
      _snack('Couldn\'t remove it: $e');
    }
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String _when(DateTime t) {
    final local = t.toLocal();
    final time = TimeOfDay.fromDateTime(local).format(context);
    final now = DateTime.now();
    if (local.year == now.year && local.month == now.month && local.day == now.day) return time;
    return '${MaterialLocalizations.of(context).formatMediumDate(local)}, $time';
  }

  /// What this device may grant. The launchpad caps it anyway; offering
  /// more than it will give would just be a lie in a menu.
  VideoReach get _mine => _proxy.videoReach(_id);

  List<VideoReach> get _grantable =>
      VideoReach.values.where((v) => v.index <= _mine.index).toList();

  Future<void> _setVideo(PairedDevice d, VideoReach v, bool recursive) async {
    try {
      await _proxy.setDeviceVideo(_id, d.id, v, recursive: recursive);
      await _load();
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _deviceName(String id) => _devices?.where((d) => d.id == id).firstOrNull?.name ?? 'a removed device';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = _created;
    return Scaffold(
      appBar: AppBar(title: Text('Share ${widget.home.name}')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Invite someone to listen to ${widget.home.name}. They can play its music, '
                'but can\'t invite others.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _label,
                maxLength: 64,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Who it\'s for (optional)'),
              ),
            ),
            RadioGroup<InvitationValidity>(
              groupValue: _valid,
              onChanged: (v) => setState(() => _valid = v!),
              child: const Column(children: [
                RadioListTile(value: InvitationValidity.tenMinutes, title: Text('Scan here, now'),
                    subtitle: Text('Valid 10 minutes')),
                RadioListTile(value: InvitationValidity.day, title: Text('Send a link'),
                    subtitle: Text('Valid 1 day')),
                RadioListTile(value: InvitationValidity.week, title: Text('Send a link, valid longer'),
                    subtitle: Text('Valid 7 days')),
              ]),
            ),
            if (_grantable.length > 1) ...[
              const _Heading('Downloading video away from home'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                    'Films are downloaded, not streamed. A film is about a gigabyte an '
                    'hour, on the home connection \u2014 and through the satellite, on the '
                    'relay its owner runs. Music is unaffected.',
                    style: theme.textTheme.bodySmall),
              ),
              RadioGroup<VideoReach>(
                groupValue: _video,
                onChanged: (v) => setState(() => _video = v!),
                child: Column(children: [
                  for (final v in _grantable)
                    RadioListTile(value: v, title: Text(v.label), subtitle: Text(v.note)),
                ]),
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: _creating ? null : _invite,
                icon: const Icon(Icons.person_add),
                label: const Text('Create invitation'),
              ),
            ),
            if (created != null) _Created(
              invitation: created,
              expires: _when(created.expires),
              onSend: (button) => _send(created, button),
              onDone: () => setState(() => _created = null),
            ),
            if (_error != null)
              ListTile(
                leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
                title: Text('$_error'),
                trailing: TextButton(onPressed: _load, child: const Text('Try again')),
              ),
            if (_pending case final pending? when pending.isNotEmpty) ...[
              const _Heading('Waiting to be used'),
              for (final inv in pending)
                ListTile(
                  leading: const Icon(Icons.mail_outline),
                  title: Text(inv.label ?? 'Anyone'),
                  subtitle: Text('Until ${_when(inv.expires)}'),
                  trailing: TextButton(onPressed: () => _cancel(inv), child: const Text('Cancel')),
                ),
            ],
            if (_devices case final devices?) ...[
              const _Heading('Paired devices'),
              for (final d in devices)
                ListTile(
                  leading: Icon(d.canInvite ? Icons.admin_panel_settings_outlined : Icons.smartphone),
                  title: Text(d.self ? '${d.name} (this device)' : d.name),
                  subtitle: Text([
                    if (d.label != null && d.label != d.name) 'for ${d.label}',
                    d.canInvite ? 'can invite others' : 'listens',
                    if (d.video != VideoReach.home) 'video ${d.video.short}',
                    if (d.invitedBy != null) 'invited by ${d.mine ? 'you' : _deviceName(d.invitedBy!)}',
                    if (d.lastSeen != null) 'last seen ${_when(d.lastSeen!)}',
                  ].join(' · ')),
                  trailing: d.mine
                      ? Row(mainAxisSize: MainAxisSize.min, children: [
                          if (_grantable.length > 1)
                            _VideoMenu(
                              device: d,
                              grantable: _grantable,
                              hasSubShares: devices.any((o) => o.invitedBy == d.id),
                              onChosen: (v, recursive) => _setVideo(d, v, recursive),
                            ),
                          IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: () => _revoke(d),
                          ),
                        ])
                      : null,
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text('You can remove the devices you invited. The others are managed on the '
                    'launchpad\'s console, at home.'),
              ),
            ] else if (_error == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          ],
        ),
      ),
    );
  }
}

/// The invitation just made: its QR code, and a button to send the link.
class _Created extends StatelessWidget {
  final HomeInvitation invitation;
  final String expires;
  final void Function(BuildContext button) onSend;
  final VoidCallback onDone;

  const _Created({required this.invitation, required this.expires, required this.onSend, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final qr = invitation.qr;
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          if (qr != null)
            ColoredBox(
              color: Colors.white,
              child: Image.memory(qr, width: 240, height: 240, filterQuality: FilterQuality.none),
            ),
          const SizedBox(height: 12),
          Text(
            'In Minstrel on the other phone: Add home, then scan this code or paste the link. '
            'It works once, until $expires.',
            textAlign: TextAlign.center,
          ),
          if (invitation.homeOnly) ...[
            const SizedBox(height: 8),
            Text(
              'This home has no outside address or satellite, so the invitation works only on its network.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
            Builder(
              builder: (button) => FilledButton.icon(
                onPressed: () => onSend(button),
                icon: const Icon(Icons.share),
                label: const Text('Send link'),
              ),
            ),
            TextButton(onPressed: onDone, child: const Text('Done')),
          ]),
          const SizedBox(height: 8),
          Text(
            'Anyone with the link can pair until it\'s used. Send it privately.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;

  const _Heading(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

/// The video choice for one device this phone invited.
///
/// A menu rather than a row of controls: most devices never need it
/// changed, and the sharing page is already a long list.
class _VideoMenu extends StatelessWidget {
  final PairedDevice device;
  final List<VideoReach> grantable;
  final bool hasSubShares;
  final void Function(VideoReach, bool recursive) onChosen;

  const _VideoMenu({
    required this.device,
    required this.grantable,
    required this.hasSubShares,
    required this.onChosen,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<(VideoReach, bool)>(
        tooltip: 'Video away from home',
        icon: const Icon(Icons.movie_outlined),
        onSelected: (choice) => onChosen(choice.$1, choice.$2),
        itemBuilder: (context) => [
          for (final v in grantable)
            CheckedPopupMenuItem(
              value: (v, false),
              checked: device.video == v,
              child: Text(v.label),
            ),
          // Only where it can mean something: a device nobody was invited
          // through has nothing to apply it to.
          if (hasSubShares) ...[
            const PopupMenuDivider(),
            for (final v in grantable)
              PopupMenuItem(
                value: (v, true),
                child: Text('${v.label}, and everyone they invited'),
              ),
          ],
        ],
      );
}
