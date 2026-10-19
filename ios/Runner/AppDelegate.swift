import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// One engine for the phone screen and CarPlay. CarPlay may start the app
  /// with no phone screen at all, so the engine can't belong to either.
  lazy var engine = FlutterEngine(name: "minstrel")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    engine.run()
    GeneratedPluginRegistrant.register(with: engine)
    CarPlayBridge.shared.attach(engine.binaryMessenger)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
