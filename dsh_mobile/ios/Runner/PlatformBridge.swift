import Flutter
import UIKit
import Security

/// iOS 侧对 Android `MainActivity` 那套 MethodChannel 的等价实现。
///
/// ## 为什么是一个文件而不是一个 Flutter 插件
///
/// Android 侧把这些能力直接摊在 `MainActivity` / `SecureStoreBridge` 里，没有
/// 做成 pub 包 —— 因为它们的消费者只有本 App，做插件只多一层 version/build 负担。
/// iOS 侧保持同一策略：一个 `PlatformBridge` 类，在 `AppDelegate` 里注册，
/// 与 Dart 侧的 7 个通道名逐字对应。
///
/// ## 与 Android 的逐条对照（差异是刻意的，不是没写完）
///
/// | 通道 | Android | iOS |
/// |---|---|---|
/// | `dsh_mobile/secure` | AndroidKeyStore + AES/GCM | **Keychain**（系统托管加密、Secure Enclave 保护） |
/// | `dsh_mobile/url` | `ACTION_VIEW` | `UIApplication.open` |
/// | `dsh_mobile/deeplink` | `dshmobile://` intent-filter | `CFBundleURLTypes` + `application(_:open:)` |
/// | `dsh_mobile/file` | FileProvider + `ACTION_VIEW` | 缓存目录落盘 + `UIActivityViewController` |
/// | `dsh_mobile/foreground` | 前台服务保活 | **如实回 false** —— iOS 没有前台服务，见下 |
/// | `dsh_mobile/share` | SEND intent | 需 Share Extension（本版未做），回 nil 让 Dart 侧走无分享分支 |
/// | `dsh_mobile/widget` | RemoteViews 小组件 | 需 WidgetKit Extension（本版未做），回 false |
///
/// 后三项"没做"的处理原则是**如实回答**，不是假装成功：Dart 侧每个调用点都已
/// 把 `false` / `nil` / `MissingPluginException` 当成正常路径（见
/// `lib/services/platform_services.dart` 与 `notification_service.dart` 的注释），
/// 所以这里回 false 不会让界面上出现假的"已开启"。
final class PlatformBridge: NSObject {

    private weak var registrar: FlutterPluginRegistrar?

    /// 深链接通道。冷启动时 `pendingDeepLinkSession` 先暂存，等 Dart 侧来消费；
    /// 运行中收到深链接则直接反向 `invokeMethod("openSession")` 推过去。
    private var deepLinkChannel: FlutterMethodChannel?

    /// 冷启动遗留的会话 id（App 未运行时点通知进来的那条）。
    private var pendingDeepLinkSession: String?

    init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        super.init()
        let messenger = registrar.messenger()
        registerSecure(messenger)
        registerUrl(messenger)
        registerFile(messenger)
        registerForeground(messenger)
        registerShare(messenger)
        registerWidget(messenger)
        registerDeepLink(messenger)
    }

    // MARK: - dsh_mobile/secure（Keychain）

    /// 敏感字符串（网关 token / authCode）的落盘。
    ///
    /// **与 Android 的实现差异**：Android 需要自己生成一把不可导出的密钥并在原生
    /// 侧做 AES/GCM，因为 Android 没有系统级的、按应用隔离的凭据存储。iOS 有 ——
    /// 就是 Keychain。所以这里**不做任何手工加密**：直接把明文交给 Security 框架，
    /// 由系统负责加密与访问控制。
    ///
    /// 关键属性：
    /// * `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    ///   选它而不是 `WhenUnlocked`：网关重连可能在锁屏状态下由后台任务触发，
    ///   `WhenUnlocked` 会让那条路径读不到 token 而静默失败。
    ///   `ThisDeviceOnly` 让它不进 iCloud Keychain、不随备份迁移到新设备 ——
    ///   与 Android `allowBackup="false"` 的取向一致：凭据不该跟着备份跑。
    /// * `kSecAttrService` 用固定的服务名，`kSecAttrAccount` 就是 Dart 侧的 key。
    ///
    /// 降级契约与 Android 一致：任何失败都如实回错误码，由 Dart 侧
    /// `SecureStore` 退到进程内存储（它已经把 `PlatformException` 当正常路径）。
    private func registerSecure(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "dsh_mobile/secure", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "ping":
                // 探测探针：写一条临时项再删掉，确认 Keychain 真的可用。
                // 某些企业策略 / 无密码的设备上 Keychain 会拒绝写入，此时必须
                // 回 false 让 Dart 侧立刻降级，而不是等第一次真正写 token 时才发现。
                let probeKey = "__dsh_keychain_probe__"
                let ok = Keychain.set(key: probeKey, value: "1") && Keychain.delete(key: probeKey)
                result(ok)
            case "write":
                guard let args = call.arguments as? [String: Any],
                      let key = args["key"] as? String,
                      let value = args["value"] as? String,
                      !key.isEmpty else {
                    result(FlutterError(code: "bad-args", message: "key and value are required", details: nil))
                    return
                }
                if Keychain.set(key: key, value: value) {
                    result(true)
                } else {
                    result(FlutterError(code: "secure-failed", message: "Keychain write failed", details: nil))
                }
            case "read":
                guard let args = call.arguments as? [String: Any],
                      let key = args["key"] as? String, !key.isEmpty else {
                    result(FlutterError(code: "bad-args", message: "key is required", details: nil))
                    return
                }
                // 读不到 = null。这**不是**错误：Dart 侧用它区分"没存过"和"存过但坏了"。
                result(Keychain.get(key: key))
            case "delete":
                guard let args = call.arguments as? [String: Any],
                      let key = args["key"] as? String, !key.isEmpty else {
                    result(FlutterError(code: "bad-args", message: "key is required", details: nil))
                    return
                }
                _ = Keychain.delete(key: key)
                // 删不存在的项也算成功（幂等），与 Android 侧一致。
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - dsh_mobile/url

    /// 打开外部 URL。仅用于"更新说明 / 发布页"这类**由用户主动点**的外部跳转。
    ///
    /// 为什么不让 Dart 直接调 `url_launcher`：Android 侧为了省一个带传递依赖的
    /// 插件，用 MethodChannel 手写了 12 行；iOS 侧跟着手写保持两个平台对称，
    /// 排查时只需要看一个地方。
    private func registerUrl(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "dsh_mobile/url", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "openUrl" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard let args = call.arguments as? [String: Any],
                  let raw = args["url"] as? String,
                  let url = URL(string: raw) else {
                result(FlutterError(code: "bad-args", message: "url is required", details: nil))
                return
            }
            // 只放行 http/https。否则一个被污染的网关返回体就能让 App 去开
            // 任意 scheme（比如 tel: / shortscuts:），这是不必要的攻击面。
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                result(false)
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { opened in
                    result(opened)
                }
            }
        }
    }

    // MARK: - dsh_mobile/file

    /// 把 Dart 读好的字节落盘，再交给系统预览/分享。
    ///
    /// 与 Android 的差异：Android 用 FileProvider + `ACTION_VIEW` 直接丢给能处理
    /// 该 MIME 的应用；iOS 没有等价的"按 MIME 派发"，标准做法是
    /// `UIActivityViewController`（系统分享面板，其中包含"用某 App 打开"）。
    private func registerFile(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "dsh_mobile/file", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "openBytes" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard let args = call.arguments as? [String: Any],
                  let typed = args["bytes"] as? FlutterStandardTypedData,
                  !typed.data.isEmpty else {
                result(false)
                return
            }
            let name = (args["name"] as? String) ?? "deliverable"
            DispatchQueue.main.async {
                let ok = self?.presentShareSheet(name: name, data: typed.data) ?? false
                result(ok)
            }
        }
    }

    /// 写进 `Caches/deliverables/` 再弹系统分享面板。返回是否真的弹出来了。
    private func presentShareSheet(name: String, data: Data) -> Bool {
        guard let root = Self.topViewController() else { return false }
        // 文件名要清洗：交付物名来自模型输出，可能带 `/`、`..` 之类的路径片段。
        let safe = name.replacingOccurrences(
            of: "[^A-Za-z0-9._\\-\\u4e00-\\u9fa5]",
            with: "_",
            options: .regularExpression
        )
        let finalName = safe.isEmpty ? "deliverable" : safe
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("deliverables", isDirectory: true) else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(finalName)
            try data.write(to: url, options: .atomic)
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            // iPad 上 UIActivityViewController 是 popover，必须给锚点，
            // 否则直接崩在 present 上（iOS 上这是最常见的"只在平板上炸"的坑）。
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = root.view
                pop.sourceRect = CGRect(
                    x: root.view.bounds.midX,
                    y: root.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                pop.permittedArrowDirections = []
            }
            root.present(sheet, animated: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - dsh_mobile/foreground

    /// **iOS 没有 Android 那种"前台服务"**，这里如实回 false。
    ///
    /// Android 侧靠一个常驻通知的前台服务让进程在后台活着，从而保持 WebSocket
    /// 不断线。iOS 的对应手段只有三种，本 App 都不适用：
    ///
    /// 1. 后台音频（`UIBackgroundModes: audio`）—— 业内常见的"放静音音频保活"
    ///    做法，会被 App Review 直接拒（4.2 / 2.5.4），且极耗电。
    /// 2. `voip` 推送 —— 只有真正的 VoIP 应用可用，同样要审核。
    /// 3. `beginBackgroundTask` —— 只买到约 30 秒，撑不住长连接。
    ///
    /// 所以 iOS 的离线提醒走的是**服务端 ntfy 推送**（`push_settings_view` 里配置的
    /// 那条链路，与 Android 同源），而不是"App 在后台挂着 WS"。这不是降级，
    /// 是 iOS 上唯一正确的架构：进程被杀也能收到通知。
    ///
    /// Dart 侧 `enableBackground()` 拿到 false 会如实告诉用户"后台保活不可用"，
    /// 不会假装已开启 —— 这是它本来就有的契约（见该方法注释）。
    private func registerForeground(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "dsh_mobile/foreground", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "startForeground", "stopForeground":
                result(false)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - dsh_mobile/share

    /// iOS 的"系统分享进来"必须由 **Share Extension** 提供，App 本体收不到。
    ///
    /// 本版没做 Extension（它要独立 target、独立 Info.plist、App Group 与
    /// 主 App 共享容器，是一次独立的工程改动）。所以这里回 nil，让 Dart 侧
    /// 走"没有待处理分享"的正常分支 —— `ShareReceiver.consumePending()` 的
    /// 实现本来就把 null 当正常路径。
    private func registerShare(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "dsh_mobile/share", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            if call.method == "consumePending" {
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - dsh_mobile/widget

    /// 桌面小组件需要 WidgetKit Extension（独立 target + App Group 共享状态），
    /// 与 Share Extension 同属"本版未做"。回 false 让 `WidgetBridge` 静默忽略。
    private func registerWidget(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "dsh_mobile/widget", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "update", "clear":
                result(false)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - dsh_mobile/deeplink

    private func registerDeepLink(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "dsh_mobile/deeplink", binaryMessenger: messenger)
        deepLinkChannel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            if call.method == "consumePending" {
                let session = self?.pendingDeepLinkSession
                self?.pendingDeepLinkSession = nil
                result(session)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// 由 `AppDelegate.application(_:open:options:)` 调进来。
    ///
    /// 两个方向都要覆盖，与 Android 的 `captureDeepLink` 一一对应：
    /// * 冷启动（App 没跑）→ 先存进 `pendingDeepLinkSession`，等 Dart 侧来取；
    /// * 运行中 → 直接 `openSession` 推过去，App 立刻跳到那个会话。
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "dshmobile" else { return }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let session = comps.queryItems?.first(where: { $0.name == "session" })?.value
        guard let session, !session.isEmpty else { return }
        pendingDeepLinkSession = session
        deepLinkChannel?.invokeMethod("openSession", arguments: ["sessionId": session])
    }

    // MARK: - Helpers

    /// 找到当前最顶层、且不在 present 中的 VC。
    ///
    /// 直接拿 `keyWindow.rootViewController` 在"已经有 sheet/弹窗"时会 present 失败
    /// 并打一条 warning（面板静默不出现），所以必须往下找到真正可用的那个。
    static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Keychain 的最小封装：只需要"按 key 存一段明文 / 取回来 / 删掉"。
///
/// 不做额外加密的理由见 `registerSecure` 的注释 —— Keychain 本身就是按应用隔离、
/// 由系统加密的存储，再套一层 AES 只会把密钥管理问题搬到自己身上。
private enum Keychain {

    /// 固定的 service 名。改它等于让所有老用户的凭据"消失"（新 service 下查不到），
    /// 所以它是一个**不该随手改**的常量。
    static let service = "com.example.dshMobile.secure"

    private static func query(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    @discardableResult
    static func set(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var q = query(key: key)
        // 先删后加：SecItemUpdate 在"项不存在"时返回 errSecItemNotFound，
        // 还要再补一次 Add，代码更长且没有实际收益。这里是"最多一个"的小表。
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func get(key: String) -> String? {
        var q = query(key: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let status = SecItemDelete(query(key: key) as CFDictionary)
        // errSecItemNotFound 视为成功：删一个不存在的东西，结果与"已删除"一致。
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
