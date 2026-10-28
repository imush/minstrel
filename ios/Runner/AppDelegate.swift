import AVFoundation
import Flutter
import MediaPlayer
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
    SystemVolume.shared.attach(engine.binaryMessenger)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// The phone's media volume, 0 to 1, for the slider on Now Playing
/// (lib/playback/system_volume.dart). iOS lets apps change it only through
/// the system's own volume control, MPVolumeView, so its slider is kept off
/// screen and set from Dart.
final class SystemVolume: NSObject, FlutterStreamHandler {
  static let shared = SystemVolume()

  private lazy var view: MPVolumeView = {
    let v = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 40))
    v.isHidden = false
    v.alpha = 0.01
    return v
  }()
  private var events: FlutterEventSink?
  private var observation: NSKeyValueObservation?

  func attach(_ messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "org.minstrelplayer/volume", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self else { return }
        switch call.method {
        case "get":
          result(Double(AVAudioSession.sharedInstance().outputVolume))
        case "set":
          let value = (call.arguments as? NSNumber)?.floatValue ?? 0
          self.slider()?.setValue(value, animated: false)
          self.slider()?.sendActions(for: .valueChanged)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    FlutterEventChannel(name: "org.minstrelplayer/volume/changes", binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  /// The view must be in a window for its slider to take effect.
  private func slider() -> UISlider? {
    if view.window == nil {
      let window = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }
        .first
      window?.addSubview(view)
    }
    return view.subviews.compactMap { $0 as? UISlider }.first
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.events = events
    // Changes with the side buttons, or from Control Center.
    observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
      guard let v = change.newValue else { return }
      DispatchQueue.main.async { self?.events?(Double(v)) }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    observation = nil
    events = nil
    return nil
  }
}
