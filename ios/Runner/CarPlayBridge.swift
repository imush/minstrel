import Flutter
import Foundation

/// One entry in CarPlay's lists, as the Dart car library describes it.
struct CarNode {
  let id: String
  let title: String
  let subtitle: String?
  let art: URL?
  let browsable: Bool
  let playable: Bool

  init?(_ map: [String: Any]) {
    guard let id = map["id"] as? String, let title = map["title"] as? String else { return nil }
    self.id = id
    self.title = title
    subtitle = map["subtitle"] as? String
    art = (map["art"] as? String).flatMap(URL.init(string:))
    browsable = map["browsable"] as? Bool ?? false
    playable = map["playable"] as? Bool ?? false
  }
}

/// The channel to the Dart car library (lib/car/carplay.dart).
final class CarPlayBridge {
  static let shared = CarPlayBridge()

  private var channel: FlutterMethodChannel?
  private var ready = false
  private var waiting: [() -> Void] = []

  /// Called with the id of a list whose contents changed: "" for the tabs.
  var onChanged: ((String) -> Void)?

  func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "org.minstrelplayer/carplay", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "ready":
        // Dart is listening now; send what CarPlay asked for meanwhile.
        self.ready = true
        let waiting = self.waiting
        self.waiting = []
        waiting.forEach { $0() }
        result(nil)
      case "changed":
        self.onChanged?(call.arguments as? String ?? "")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  func call(_ method: String, _ arguments: Any? = nil, done: @escaping (Any?) -> Void) {
    let send = { [weak self] in
      guard let channel = self?.channel else { return done(nil) }
      channel.invokeMethod(method, arguments: arguments) { result in
        done(result is FlutterError || (result as AnyObject) === FlutterMethodNotImplemented ? nil : result)
      }
    }
    if ready { send() } else { waiting.append(send) }
  }

  func nodes(_ method: String, id: String? = nil, done: @escaping ([CarNode]) -> Void) {
    call(method, id.map { ["id": $0] }) { result in
      done((result as? [[String: Any]] ?? []).compactMap(CarNode.init))
    }
  }
}
