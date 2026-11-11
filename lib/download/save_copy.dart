import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:minstrel_core/minstrel_core.dart';
import 'package:path_provider/path_provider.dart';

import '../app_services.dart';
import '../cache/device_storage.dart';

/// Fetches [item] and puts it where the device keeps what people download:
/// the shared Downloads collection on Android, and whatever the document
/// picker is pointed at on iOS, which has no Downloads folder of its own.
///
/// Deliberately not the music cache. A film is not kept for listening, so
/// the cache's budget and eviction have nothing useful to say about one.
///
/// Not the share sheet either, which was tried first and cannot do this:
/// it copies the whole file on the main thread before offering anywhere to
/// put it, so a film froze the app and never reached a sheet at all.
Future<void> saveACopy(BuildContext context, DidlItem item) async {
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
    await cleanSaveScratch();
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
    if (ok != null) {
      if (context.mounted) await _explain(context, item.title, ok);
      return;
    }

    final saved = await DeviceStorage.saveCopy(file,
        name: saveFileName(item, res), mimeType: res.mimeType);
    switch (saved.status) {
      case 'saved':
        messenger.showSnackBar(SnackBar(
          content: Text('Saved ${saved.where ?? saveFileName(item, res)}'
              '${Platform.isAndroid ? ' to Downloads' : ''}'),
        ));
      case 'cancelled':
        messenger.showSnackBar(const SnackBar(content: Text('Not saved')));
      default:
        if (context.mounted) {
          await _explain(
              context,
              item.title,
              Platform.isAndroid
                  ? 'Saving to Downloads needs Android 10 or later.'
                  : 'This device offered nowhere to put it.');
        }
    }
  } on Object catch (e) {
    if (context.mounted) await _explain(context, item.title, '$e');
  } finally {
    progress.dispose();
  }
}

/// Throws away what saving a copy leaves behind: a film can sit in this
/// app's cache taking gigabytes, which on a music player is the last thing
/// anybody expects to be holding.
///
/// Two directories. `saving` is where the fetch lands before it is handed
/// over. `share_plus` is from the version that tried the share sheet,
/// which copied the file into a folder of its own and cleaned it up only on
/// the next share — testers who ran that build have one stranded there.
///
/// Done on the way in rather than out, since whatever is copying the file
/// may not be finished when the picker closes.
Future<void> cleanSaveScratch() async {
  final tmp = (await getTemporaryDirectory()).path;
  for (final name in ['saving', 'share_plus']) {
    try {
      final dir = Directory('$tmp/$name');
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // In use, or already gone; the next start tries again.
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

/// Fetches [from] into [into]. Null when that worked, otherwise what went
/// wrong, in words worth showing somebody.
Future<String?> _fetch(
  Uri from,
  File into,
  ValueNotifier<double?> progress,
  _Flag cancelled,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  IOSink? sink;
  try {
    final res = await client.getUrl(from).then((r) => r.close());
    // Some servers answer every request with a range, whether or not one
    // was asked for.
    if (res.statusCode != HttpStatus.ok && res.statusCode != HttpStatus.partialContent) {
      await res.drain<void>();
      return switch (res.statusCode) {
        HttpStatus.notFound => 'The server no longer has this file (404).',
        HttpStatus.forbidden => 'The server refused it (403). A home can be set '
            'to allow video only on its own network.',
        HttpStatus.unauthorized => 'The server wanted credentials we do not have (401).',
        final code => 'The server answered $code.',
      };
    }
    final total = res.contentLength;
    var got = 0;
    sink = into.openWrite();
    await for (final chunk in res) {
      if (cancelled.set) return null;
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress.value = got / total;
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (got == 0) return 'The server sent nothing at all.';
    // A part of a film is not worth handing anybody.
    final written = await into.length();
    if (total > 0 && written != total) {
      return 'The transfer stopped early: ${written ~/ 1048576} MB of '
          '${total ~/ 1048576} MB.';
    }
    return null;
  } on Object catch (e) {
    return '$e';
  } finally {
    await sink?.close();
    client.close(force: true);
  }
}

/// Says why nothing was saved, somewhere it can be read rather than in a
/// snack bar that has gone by the time it is noticed.
Future<void> _explain(BuildContext context, String title, String why) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Couldn\'t save it'),
        content: Text('$title\n\n$why'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );

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
