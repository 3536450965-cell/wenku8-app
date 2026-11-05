import Flutter
import UIKit

/// 公开快照没有包含这个插件，这里给出一个空实现，
/// 只保证 `AppDelegate` 里的注册调用可以编译通过。
/// 局域网发现在当前构建里不可用，调用会返回明确错误。
final class NativeLanDiscoveryPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "org.mewx.wenku8/lan_discovery", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(NativeLanDiscoveryPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterError(code: "unavailable", message: "当前构建不支持局域网发现", details: nil))
  }
}