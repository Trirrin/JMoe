import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 注册 JMoe 自定义通道（对应 Android 的 MainActivity 里的
    // jmoe/reader 与 jmoe/share 两个 MethodChannel）
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "JmoeChannel") {
      JmoeChannelHandler.register(with: registrar)
    }
  }
}
