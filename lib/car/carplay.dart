import 'package:flutter/services.dart';

import 'car_library.dart';

/// CarPlay's screens are native templates (ios/Runner/CarPlay*.swift); they
/// read the same [CarLibrary] as Android Auto over this channel.
class CarPlayBridge {
  static const _channel = MethodChannel('org.minstrelplayer/carplay');

  final CarLibrary car;

  CarPlayBridge(this.car);

  Future<void> start() async {
    _channel.setMethodCallHandler(_handle);
    car.changed.listen((id) => _channel.invokeMethod('changed', id).catchError((Object _) {}));
    // CarPlay may have connected first and be waiting for this.
    await _channel.invokeMethod('ready');
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'roots':
        return [for (final n in car.roots()) _encode(n)];
      case 'children':
        return [for (final n in await car.children(args['id'] as String)) _encode(n)];
      case 'play':
        await car.play(args['id'] as String);
        return null;
    }
    throw MissingPluginException(call.method);
  }

  static Map<String, Object?> _encode(CarNode n) => {
        'id': n.id,
        'title': n.title,
        'subtitle': n.subtitle,
        'art': n.art?.toString(),
        'browsable': n.browsable,
        'playable': n.playable,
      };
}
