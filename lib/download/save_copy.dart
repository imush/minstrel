import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_services.dart';

/// Fetches [item] and hands it to the system's own save sheet, where the
/// person decides what becomes of it — Downloads, Files, a cloud drive.
///
/// Deliberately not the music cache. A film is not kept for listening, so
/// the cache's budget and eviction have nothing useful to say about one.
/// The sheet also costs no storage permission and behaves the same on both
/// platforms, which writing to a Downloads folder does not: Android's
/// shared one needs an API level we don't require, and iOS has none.
Future<void> saveACopy(BuildContext context, DidlItem item, {Rect? from}) async {
  final messenger = ScaffoldMessenger.of(context);
  final res = biggestResource(item);
  if (res == null) {
    messenger.showSnackBar(const SnackBar(content: Text('Nothing here to save')));
    return;
  }
  final refusal = _refusedBy(res.uri);
  if (refusal != null) {
    messenger.showSnackBar(SnackBar(content: Text(refusal)));
    return;
  }

  final dir = Directory('${(await getTemporaryDirectory()).path}/saving');
  final progress = ValueNotifier<double?>(null);
  final cancelled = _Flag();
  File? file;
  try {
    // Whatever a previous save left behind: the sheet copies what it is
    // given, so nothing here needs to outlive the share.
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    file = File('${dir.path}/${saveFileName(item, res)}');

    if (!context.mounted) return;
    // Closed from two places — cancelling, and finishing — so closing is
    // done once and only once. Popping twice would take the page with it.
    var up = true;
    void close() {
      if (!up) return;
      up = false;
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    unawaited(_showProgress(context, item.title, progress, () {
      cancelled.set = true;
      close();
    }));
    final ok = await _fetch(AppServices.instance.homes.proxy.rehome(res.uri), file,
        progress, cancelled);
    close();
    if (cancelled.set) return;
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t fetch ${item.title}')));
      return;
    }

    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: res.mimeType)],
      fileNameOverrides: [saveFileName(item, res)],
      sharePositionOrigin: from,
    ));
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Couldn\'t save ${item.title}: $e')));
  } finally {
    progress.dispose();
    // The sheet has taken its own copy by now.
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // It will go with the next save, or with the temporary directory.
    }
  }
}

/// The largest copy the server offers, since this is for keeping rather
/// than streaming and a thumbnail is not what anybody means by "save".
@visibleForTesting
DidlResource? biggestResource(DidlItem item) {
  final http = item.resources
      .where((r) => r.uri.isScheme('http') || r.uri.isScheme('https'))
      .toList();
  if (http.isEmpty) return null;
  http.sort((a, b) => (b.size ?? 0).compareTo(a.size ?? 0));
  return http.first;
}

/// Why this can't be fetched, when a home says so. Video away from home is
/// the owner's decision, made on the launchpad.
String? _refusedBy(Uri uri) {
  if (!HomeProxy.isHomeUrl(uri)) return null;
  final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (seg.length < 2) return null;
  final proxy = AppServices.instance.homes.proxy;
  if (proxy.videoAllowed(seg[1])) return null;
  return 'This home doesn\'t allow video away from its own network';
}

/// A file name the save sheet can offer: the server's own where it has
/// one, since that is what the file is called at home.
@visibleForTesting
String saveFileName(DidlItem item, DidlResource res) {
  final last = Uri.decodeComponent(res.uri.pathSegments.lastOrNull ?? '');
  final dot = last.lastIndexOf('.');
  if (dot > 0 && dot < last.length - 1 && dot >= last.length - 6) return _safe(last);
  final ext = switch (res.mimeType) {
    'video/mp4' => '.mp4',
    'video/x-matroska' => '.mkv',
    'video/quicktime' => '.mov',
    'video/mpeg' => '.mpg',
    'video/x-msvideo' => '.avi',
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    _ => '',
  };
  return _safe('${item.title}$ext');
}

/// Nothing that could climb out of the directory or upset a file system.
String _safe(String name) {
  final clean = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').trim();
  return clean.isEmpty || clean == '.' || clean == '..' ? 'download' : clean;
}

Future<bool> _fetch(
  Uri from,
  File into,
  ValueNotifier<double?> progress,
  _Flag cancelled,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  IOSink? sink;
  try {
    final res = await client.getUrl(from).then((r) => r.close());
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      return false;
    }
    final total = res.contentLength;
    var got = 0;
    sink = into.openWrite();
    await for (final chunk in res) {
      if (cancelled.set) return false;
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress.value = got / total;
    }
    await sink.flush();
    await sink.close();
    sink = null;
    // A part of a film is not worth handing anybody.
    return total < 0 || await into.length() == total;
  } on Object {
    return false;
  } finally {
    await sink?.close();
    client.close(force: true);
  }
}

Future<void> _showProgress(
  BuildContext context,
  String title,
  ValueNotifier<double?> progress,
  VoidCallback onCancel,
) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Fetching'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 16),
            ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (context, value, _) => LinearProgressIndicator(value: value),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      ),
    );

/// A bool the fetch and the dialog can both see.
class _Flag {
  bool set = false;
}
