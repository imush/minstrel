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
        case "saveCopy":
          guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String
          else {
            result(FlutterError(code: "arguments", message: "path is required", details: nil))
            return
          }
          Self.export(URL(fileURLWithPath: path), result)
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

  /// Hands a file the app has already fetched to the document picker, which
  /// is where somebody chooses what becomes of it — On My iPhone, iCloud
  /// Drive, or anywhere else they have.
  ///
  /// iOS has no Downloads folder to write to, and this is its equivalent:
  /// the system does the copying, so a film never passes through memory or
  /// holds up the app.
  private static func export(_ file: URL, _ result: @escaping FlutterResult) {
    guard
      let root = UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } })
        .first?.rootViewController
    else {
      result(["status": "unsupported"])
      return
    }
    let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
    let delegate = ExportDelegate(result)
    picker.delegate = delegate
    // The picker holds only a weak delegate, so it is kept alive here until
    // it has answered.
    exporting = delegate
    root.present(picker, animated: true)
  }

  private static var exporting: ExportDelegate?

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

/// Answers the save once the document picker is done with it.
private final class ExportDelegate: NSObject, UIDocumentPickerDelegate {
  private var result: FlutterResult?

  init(_ result: @escaping FlutterResult) {
    self.result = result
  }

  /// Called once, whichever way it ends; the picker is dismissed by itself.
  private func answer(_ value: [String: Any]) {
    result?(value)
    result = nil
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    answer(["status": "saved", "where": urls.first?.lastPathComponent ?? ""])
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    answer(["status": "cancelled"])
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
