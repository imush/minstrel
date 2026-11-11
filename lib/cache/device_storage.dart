import 'package:flutter/services.dart';

/// How much room the volume holding the cache has.
class StorageSpace {
  /// Bytes an app may still write.
  final int free;

  /// The size of the volume.
  final int total;

  const StorageSpace({required this.free, required this.total});

  /// How full the volume is, 0 to 1.
  double get full => total <= 0 ? 0 : (total - free) / total;
}

/// The free space on this device.
///
/// Dart has no call for it, so it comes from the platform:
/// android/…/MinstrelApplication.kt and ios/Runner/AppDelegate.swift.
class DeviceStorage {
  static const _channel = MethodChannel('org.minstrelplayer/storage');

  /// Null where the platform won't say. Callers treat that as "room enough":
  /// refusing to cache because we couldn't measure would turn a missing
  /// platform method into a feature that silently does nothing.
  static Future<StorageSpace?> space() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('space');
      final free = (m?['free'] as num?)?.toInt();
      final total = (m?['total'] as num?)?.toInt();
      if (free == null || total == null) return null;
      return StorageSpace(free: free, total: total);
    } on Object {
      return null;
    }
  }

  /// Keeps [path] out of the owner's backups. Cached music is a copy of a
  /// library that lives at home, so backing it up would spend somebody's
  /// iCloud quota on something re-fetchable.
  ///
  /// Does the work on iOS; on Android the manifest's backup rules cover it
  /// and this is a no-op.
  static Future<void> excludeFromBackup(String path) async {
    try {
      await _channel.invokeMethod<void>('excludeFromBackup', path);
    } on Object {
      // Older build without the method, or a platform that has no backups.
    }
  }
}
