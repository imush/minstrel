import 'package:flutter/services.dart';

/// The phone's own media volume, the one the side buttons change, from 0
/// to 1. Set natively: ios/Runner/AppDelegate.swift and
/// android/…/MinstrelApplication.kt.
class SystemVolume {
  static const _channel = MethodChannel('org.minstrelplayer/volume');
  static const _events = EventChannel('org.minstrelplayer/volume/changes');

  /// The current volume, or null where it can't be changed (a fixed-volume
  /// Android device, or no platform support).
  static Future<double?> get() async {
    try {
      return (await _channel.invokeMethod<num>('get'))?.toDouble();
    } on Object {
      return null;
    }
  }

  static Future<void> set(double v) async {
    try {
      await _channel.invokeMethod<void>('set', v.clamp(0.0, 1.0));
    } on Object {
      // Not supported here; the slider isn't shown then.
    }
  }

  /// Changes made outside the app, such as with the side buttons.
  static Stream<double> get changes =>
      _events.receiveBroadcastStream().map((v) => (v as num).toDouble()).handleError((_) {});
}
