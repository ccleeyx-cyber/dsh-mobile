package com.example.dsh_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.annotation.Nullable
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    /** 分享接收：SEND intent 带来的内容，Dart 侧启动时消费一次。 */
    private var pendingShare: MutableMap<String, String>? = null

    /** 深链接带来的会话 id（离线推送点开直达），Dart 侧消费一次。 */
    private var pendingDeepLinkSession: String? = null

    /** Dart 侧建立通道后存下来，冷启动时 intent 里的深链接要能回传。 */
    private var deepLinkChannel: MethodChannel? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShareIntent(intent)
        captureDeepLink(intent)
    }

    /**
     * 把 SEND intent 的文字/图片 URI 暂存，等 Dart 侧来取。
     *
     * 图片不能只存 `content://` URI 就交给 Dart：那个 URI 的读权限只在本进程
     * 有效，Dart 侧（以及之后的 HTTP 上传）根本打不开它。所以这里立刻用
     * ContentResolver 把字节抄进 App 私有缓存，必要时先等比缩小 —— 手机直出
     * 照片 3~5MB，base64 内联会直接撞上网关 2MB 的 JSON 上限。
     */
    private fun captureShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val map = mutableMapOf<String, String>()
        if (intent.type == "text/plain") {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""
            if (text.isNotBlank()) map["text"] = text
        } else if (intent.type?.startsWith("image/") == true) {
            @Suppress("DEPRECATION")
            val uri = intent.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)
            if (uri != null) {
                val copied = copySharedImage(uri)
                if (copied != null) {
                    map["imagePath"] = copied.absolutePath
                    map["imageName"] = copied.name
                }
            }
        }
        if (map.isNotEmpty()) pendingShare = map
    }

    /**
     * 复制（必要时缩小）一张分享进来的图片到缓存目录。
     *
     * 缩小策略与相册选择保持一致：最长边 1600px、JPEG 质量 85 —— 与
     * image_picker 的压缩参数同量级，输出通常 200~500KB，安全落在内联上限内。
     * 解不出来时退回原始字节复制，让用户至少能发出原图（由 Dart 侧的上限校验
     * 决定是否拒绝），而不是静默丢失。
     */
    private fun copySharedImage(uri: android.net.Uri): java.io.File? {
        val dir = java.io.File(cacheDir, "shared").apply { mkdirs() }
        val target = java.io.File(dir, "shared-${System.currentTimeMillis()}.jpg")
        return try {
            val resolver = contentResolver
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            resolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it, null, bounds) }

            val longest = maxOf(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (longest / sample > 1600) sample *= 2

            val opts = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
            val bitmap = resolver.openInputStream(uri)?.use {
                android.graphics.BitmapFactory.decodeStream(it, null, opts)
            }
            if (bitmap == null) {
                // 解不出来（HEIC/异常编码）：按原字节复制，交给 Dart 侧判定。
                resolver.openInputStream(uri)?.use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
                return target
            }
            target.outputStream().use { output ->
                bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, output)
            }
            bitmap.recycle()
            target
        } catch (e: Exception) {
            null
        }
    }

    /**
     * `dshmobile://open?session=...` —— ntfy 推送点开后直达会话。
     *
     * 为什么需要它：离线推送（ntfy）由系统或第三方 App 弹出，点击时打开的是一个
     * URL；没有这条深链接，用户点完只会看到浏览器或 ntfy 本身，"收到提醒却进不去
     * 那一轮"等于白推。
     */
    private fun captureDeepLink(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "dshmobile") return
        val session = data.getQueryParameter("session")
        if (session.isNullOrBlank()) return
        pendingDeepLinkSession = session
        deepLinkChannel?.invokeMethod("openSession", mapOf("sessionId" to session))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 冷启动：intent 在 Activity 创建时就已就位（分享 / 深链接）。
        captureShareIntent(intent)
        captureDeepLink(intent)

        // 语音输入：App 调用 startListening，插件起原生识别器；结果与错误
        // 经 EventChannel 回传。这里只做"点击时若 App 已退到后台就把前台服务
        // 拉起来"的联动，识别本身交给 speech_to_text 插件。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_METHODS)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForeground" -> {
                        val ctx = applicationContext
                        val started = try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                ctx.startForegroundService(Intent(ctx, GatewayKeepAliveService::class.java))
                            } else {
                                ctx.startService(Intent(ctx, GatewayKeepAliveService::class.java))
                            }
                            true
                        } catch (e: Exception) {
                            // Android 12+ 对后台启动前台服务有限制；失败不是致命错误，
                            // 只是这次没有后台保活能力。明确回传 false 让 Dart 侧
                            // 能如实告诉用户"后台收不到通知"，而不是假装已经开始。
                            false
                        }
                        result.success(started)
                    }
                    "stopForeground" -> {
                        try {
                            stopService(Intent(applicationContext, GatewayKeepAliveService::class.java))
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // 打开外部 URL（APK 下载直链等）。Dart 侧没有内建的系统浏览器出口，
        // 也不用 url_launcher —— 只为一个动线加一个插件不值。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_URL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("bad-args", "url is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // 没有浏览器可处理时如实回传，Dart 侧提示复制直链。
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 分享接收：Dart 侧启动时来取一次，取走即清（避免下次启动重复注入）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_SHARE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePending" -> {
                        val share = pendingShare
                        pendingShare = null
                        result.success(share)
                    }
                    else -> result.notImplemented()
                }
            }

        // 深链接（离线推送点开直达会话）。两个方向：
        //  * Dart 侧启动后主动取一次冷启动遗留的 session id；
        //  * 运行中再收到深链接时由原生推 openSession 给它。
        val dlChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_DEEPLINK)
        deepLinkChannel = dlChannel
        dlChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumePending" -> {
                    val session = pendingDeepLinkSession
                    pendingDeepLinkSession = null
                    result.success(session)
                }
                else -> result.notImplemented()
            }
        }

        // 打开交付物：Dart 侧把字节交过来，这里落盘到缓存 + FileProvider 授权后
        // 交给系统应用。字节由 Dart 读完（带鉴权头），原生不承担网络职责。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_FILE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openBytes" -> {
                        val name = call.argument<String>("name") ?: "deliverable"
                        @Suppress("UNCHECKED_CAST")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null || bytes.isEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(openBytesInSystemApp(name, bytes))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 把字节写成缓存文件并用系统应用打开。
     *
     * 必须过 FileProvider：Android 7+ 直接传 file:// 会抛 FileUriExposedException，
     * 而缓存目录属于应用私有空间，外部应用需要显式授权才能读。
     */
    private fun openBytesInSystemApp(name: String, bytes: ByteArray): Boolean {
        return try {
            val dir = java.io.File(cacheDir, "deliverables").apply { mkdirs() }
            val safeName = name.replace(Regex("[^A-Za-z0-9._\\-\\u4e00-\\u9fa5]"), "_").ifBlank { "deliverable" }
            val file = java.io.File(dir, safeName)
            file.outputStream().use { it.write(bytes) }

            val uri = androidx.core.content.FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            val mime = android.webkit.MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            // 没有能打开它的应用 / provider 未配置：如实回 false，Dart 侧提示。
            false
        }
    }

    companion object {
        private const val CHANNEL_METHODS = "dsh_mobile/foreground"
        private const val CHANNEL_URL = "dsh_mobile/url"
        private const val CHANNEL_SHARE = "dsh_mobile/share"
        private const val CHANNEL_DEEPLINK = "dsh_mobile/deeplink"
        private const val CHANNEL_FILE = "dsh_mobile/file"
    }
}

/**
 * 前台服务：仅用于让通知在后台常驻可见。
 *
 * 为什么需要它：Android 一旦把 App 切到后台并判定它不活跃，就会回收进程，
 * WebSocket 随之断开，于是"有新事件"这件事永远不会发生 —— 推送通知也就无从谈起。
 * 前台服务是系统明确提供的、唯一能让进程长期存活的正规途径（代价是常驻一条
 * 通知，用户可见、可随时划掉）。
 *
 * 这个 Service 本身不建立网络连接，它只是"存在"以维持进程优先级；真正的
 * 连接仍在 Dart 侧。这么分是为了把网络/重连/鉴权的全部复杂度留在 Dart，
 * 而原生侧只有一个状态明确、可以审计的实现。
 */
class GatewayKeepAliveService : android.app.Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val notification: Notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ 要求 startForeground 时声明类型，且必须与 manifest 中
            // 声明的 foregroundServiceType 一致，否则抛 IllegalStateException。
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // START_STICKY：进程被系统杀掉后系统会重建它。对"随时要收到推送"这个
        // 目标是必需的 —— 但它也意味着进程在无人使用时可能被反复拉起，所以
        // Dart 侧必须在不需要通知时明确 stopForeground（上面 channel 的
        // stopForeground 分支）。
        return START_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "网关连接",
            // LOW：常驻通知不弹横幅、不震动。事件提醒走另一个 HIGH 渠道。
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "保持与网关的连接，以便在后台收到新事件提醒"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        // 点击通知回到 App。FLAG_IMMUTABLE 是 Android 12+ 的强制要求。
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("DSH 已连接网关")
            .setContentText("正在后台监听新事件")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(pi)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "dsh_keepalive"
        private const val NOTIFICATION_ID = 1001
    }
}