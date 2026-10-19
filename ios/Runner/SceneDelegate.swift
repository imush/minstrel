import Flutter
import UIKit

/// The phone screen, showing the app's shared engine.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let windowScene = scene as? UIWindowScene,
      let app = UIApplication.shared.delegate as? AppDelegate
    {
      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = FlutterViewController(
        engine: app.engine, nibName: nil, bundle: nil)
      self.window = window
      window.makeKeyAndVisible()
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    // The engine outlives this screen; free it for the next one.
    (window?.rootViewController as? FlutterViewController)?.engine.viewController = nil
    window = nil
    super.sceneDidDisconnect(scene)
  }
}
