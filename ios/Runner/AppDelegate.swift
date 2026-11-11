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
    DeviceStorage.shared.attach(engine.binaryMessenger)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Room on the volume the offline cache lives on, and keeping the cache out
/// of the user's backups (lib/cache/device_storage.dart).
final class DeviceStorage {
  static let shared = DeviceStorage()

  func attach(_ messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "org.minstrelplayer/storage", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        switch call.method {
        case "space":
          result(Self.space())
        case "excludeFromBackup":
          // Several gigabytes of cached music would otherwise go into iCloud
          // backup, where it would be pointless: it is a copy of a library
          // that lives at home and is re-fetched from there.
          guard let path = call.arguments as? String else { result(nil); return }
          var url = URL(fileURLWithPath: path)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try? url.setResourceValues(values)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
  }

  /// What iOS says an app may still write.
  ///
  /// The "important usage" figure is the one Settings shows and the one a
  /// download should trust: it counts room the system would reclaim by
  /// purging other apps' caches. It is optional, though, and simulators
  /// report none of these, so it falls back to the plain free space and
  /// then to the file system's own figures.
  private static func space() -> [String: NSNumber]? {
    // The app's own home directory: always there, and on the same volume as
    // Application Support, where the cache lives. Asking about Application
    // Support itself fails on a fresh install, before anything creates it.
    let url = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
      .volumeTotalCapacityKey,
    ])
    var free = values?.volumeAvailableCapacityForImportantUsage
    if free == nil, let plain = values?.volumeAvailableCapacity { free = Int64(plain) }
    var total = values?.volumeTotalCapacity.map { Int64($0) }
    if free == nil || total == nil {
      let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
      free = free ?? (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
      total = total ?? (attrs?[.systemSize] as? NSNumber)?.int64Value
    }
    guard let free, let total, total > 0 else { return nil }
    return ["free": NSNumber(value: free), "total": NSNumber(value: total)]
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
