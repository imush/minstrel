// The parts of the offline cache that only a real device can answer: how
// much room it has, and whether the cache directory can be kept out of
// backups. Run with:
//   flutter test integration_test/cache_platform_test.dart -d <device>
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:minstrel/cache/cache_store.dart';
import 'package:minstrel/cache/device_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Retries briefly, to let the platform channel finish registering.
Future<StorageSpace?> _spaceOnceReady() async {
  for (var i = 0; i < 20; i++) {
    final s = await DeviceStorage.space();
    if (s != null) return s;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('the platform says how much room it has', () async {
    // The channel is registered just after the engine starts, so a call in
    // the first instants of a test run can beat it. The app itself asks
    // only once prefs and the homes are up, long after.
    final space = await _spaceOnceReady();
    expect(space, isNotNull, reason: 'no storage channel on this platform');
    expect(space!.total, greaterThan(gigabyte));
    expect(space.free, greaterThan(0));
    expect(space.free, lessThanOrEqualTo(space.total));
    expect(space.full, inInclusiveRange(0, 1));
    debugPrint('free ${space.free ~/ gigabyte} GB of ${space.total ~/ gigabyte} GB '
        '(${(space.full * 100).round()}% full) '
        '→ default budget ${CacheStore.defaultBudget(space) ~/ gigabyte} GB');
  });

  test('the cache directory can be kept out of backups', () async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/music-cache');
    await dir.create(recursive: true);
    await DeviceStorage.excludeFromBackup(dir.path); // must not throw
    expect(dir.existsSync(), isTrue);
  });
}
