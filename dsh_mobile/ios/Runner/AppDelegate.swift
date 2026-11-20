import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

  /// 原生通道集合。强引用必须活到 App 结束 —— Flutter 的 messenger 只持有 handler
  /// 的闭包，若这里不保存实例，`PlatformBridge` 会在 runApp 之前被释放，
  /// 所有通道立刻变成 MissingPluginException。
  private var platformBridge: PlatformBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = registrar(forPlugin: "PlatformBridge") {
      platformBridge = PlatformBridge(registrar: registrar)
    }

    // 冷启动的深链接（App 未运行时点 ntfy 通知进来）：系统在 launchOptions 里
    // 给的是 `UIApplication.LaunchOptionsKey.url`。这一条刻意放在注册之后，
    // 保证 `pendingDeepLinkSession` 有人消费 —— Dart 侧起来后会来取。
    if let url = launchOptions?[.url] as? URL {
      platformBridge?.handleDeepLink(url)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 运行中的深链接：`dshmobile://open?session=<id>`（见 Info.plist 的
  /// CFBundleURLTypes 与 lib/services/platform_services.dart 的 DeepLinkReceiver）。
  ///
  /// 注意 FlutterAppDelegate 会把 openURL 转发给插件（比如通知插件处理它自己的
  /// 回调），所以这里**必须**调 super 并合并结果，不能直接 `return true`，
  /// 否则插件的 URL 回调会被吞掉。
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    platformBridge?.handleDeepLink(url)
    let handledByPlugin = super.application(app, open: url, options: options)
    return handledByPlugin || url.scheme?.lowercased() == "dshmobile"
  }
}
